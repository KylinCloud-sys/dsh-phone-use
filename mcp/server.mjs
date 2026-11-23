#!/usr/bin/env node
// dsh-phone-use — MCP stdio server
//
// 由 @deepseek-ai/dsh-mcp-client 拉起（见 mcp/dsh-plugin.mjs），
// 工具以 mcp__phone__* 的形式出现在每个会话里。
//
// 传输：JSON-RPC 2.0，同时兼容「一行一条 JSON」与「Content-Length 头」两种分帧。

import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const PKG_DIR = path.resolve(__dirname, '..')
const SCRIPT = path.join(PKG_DIR, 'scripts', 'phone.ps1')
const CONFIG_FILE = path.join(PKG_DIR, 'config.json')
// 固定目录：不依赖任何环境变量，装好就能用。每次 mkdtemp 会让帧缓存位置飘忽，没必要。
const BASE = path.join(os.tmpdir(), 'dsh-phone-use')
const MCP_PROTOCOL_VERSION = '2024-11-05'
const SERVER_NAME = 'phone'

let SERVER_VERSION = '0.2.0'
try {
  SERVER_VERSION = JSON.parse(fs.readFileSync(path.join(PKG_DIR, 'package.json'), 'utf8')).version
} catch {
  /* 忽略 */
}

fs.mkdirSync(BASE, { recursive: true })

/**
 * 固定帧文件：原始帧与展示帧分开。
 * - last.raw.png：无标尺原始整帧，verify / diff / baseline 只用它；
 * - last.png：最近一次给模型看的展示图（全屏或区域，带标尺）；
 * - last.region.png：显式 region 请求的展示图；
 * - baseline.png：modelBaseline（模型最近一次实际收到的整屏图，无标尺）；
 * - view-state.json：关键帧状态（opsSinceFull / baselineMeta / lastFrame）。
 * PowerShell 侧「先读 baseline 做差分、再写 out」，prev/out 不同名也安全。
 */
const FRAME = path.join(BASE, 'last.png')
const FRAME_RAW = path.join(BASE, 'last.raw.png')
const REGION = path.join(BASE, 'last.region.png')
const BASELINE = path.join(BASE, 'baseline.png')
const VIEW_STATE = path.join(BASE, 'view-state.json')
// 会话开始时清掉上一会话的 baseline/view-state（modelBaseline 必须属于当前模型上下文）。
const KEEP = new Set(['last.png', 'last.raw.png', 'last.region.png', 'plugin-boot.log'])

/** 启动时清掉历史遗留（旧版本按时间戳命名的截图等），保留关键帧与基线。 */
function sweep() {
  try {
    for (const name of fs.readdirSync(BASE)) {
      if (KEEP.has(name)) continue
      const p = path.join(BASE, name)
      try {
        const st = fs.statSync(p)
        if (st.isFile()) fs.unlinkSync(p)
      } catch {
        /* 占用中就算了 */
      }
    }
  } catch {
    /* 目录不存在等，忽略 */
  }
}
sweep()

function readConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'))
  } catch {
    return {}
  }
}

function run(req, timeoutMs = 60000) {
  const cfg = readConfig()
  if (cfg.window) req = { ...req, win: cfg.window }
  const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
  const reqFile = path.join(BASE, `mcp-req-${id}.json`)
  const resFile = path.join(BASE, `mcp-res-${id}.json`)
  fs.writeFileSync(reqFile, JSON.stringify(req), 'utf8')
  return new Promise((resolve) => {
    const child = spawn('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', SCRIPT, '-RequestFile', reqFile, '-ResultFile', resFile,
    ], { windowsHide: true })
    let err = ''
    child.stderr.on('data', (d) => { err += String(d) })
    const timer = setTimeout(() => { try { child.kill() } catch {} }, timeoutMs)
    child.on('error', (e) => {
      clearTimeout(timer)
      resolve({ ok: false, error: `无法启动 PowerShell: ${e.message}` })
    })
    child.on('close', () => {
      clearTimeout(timer)
      let out
      try {
        out = JSON.parse(fs.readFileSync(resFile, 'utf8'))
      } catch {
        out = { ok: false, error: err.trim().split(/\r?\n/).slice(-3).join(' | ') || '执行器无输出' }
      }
      try { fs.unlinkSync(reqFile) } catch {}
      try { fs.unlinkSync(resFile) } catch {}
      resolve(out)
    })
  })
}

/** 三档权限闸门，与 profile 内插件版规则一致 */
function gate(steps, confirm) {
  const cfg = readConfig()
  const mode = ['full', 'auto', 'ask'].includes(cfg.permission) ? cfg.permission : 'auto'
  const zones = Array.isArray(cfg.dangerZones) ? cfg.dangerZones : []
  if (confirm || mode === 'full') return null
  if (mode === 'ask') return { need: 'confirm', mode, reason: 'ask 模式：写操作需要显式确认' }
  for (const s of steps) {
    if (s.danger) return { need: 'confirm', mode, reason: '该步骤被标记为危险操作' }
    if ((s.op === 'tap' || s.op === 'longpress' || s.op === 'wheel') && s.at) {
      const [x, y] = String(s.at).split(',').map(Number)
      for (const z of zones) {
        const r = z && z.rect
        if (!r || r.length < 4) continue
        if (x >= r[0] && x <= r[0] + r[2] && y >= r[1] && y <= r[1] + r[3]) {
          return { need: 'confirm', mode, reason: `命中危险区域「${z.label || '未命名'}」`, at: s.at }
        }
      }
    }
  }
  return null
}

function normalizeSteps(steps) {
  if (!Array.isArray(steps)) throw new Error('steps 必须是数组')
  const out = []
  for (const raw of steps) {
    if (!raw || typeof raw !== 'object') throw new Error('steps 每一项必须是对象')
    const danger = raw.danger === true
    if (raw.tap !== undefined) out.push({ op: 'tap', at: String(raw.tap), danger })
    else if (raw.swipe !== undefined) {
      const [from, to] = String(raw.swipe).split('>').map((s) => s.trim())
      if (!from || !to) throw new Error('swipe 格式应为 "x1,y1>x2,y2"')
      out.push({ op: 'swipe', from, to, ms: raw.ms ?? 300, danger })
    } else if (raw.longpress !== undefined) out.push({ op: 'longpress', at: String(raw.longpress), ms: raw.ms ?? 800, danger })
    else if (raw.openmenu !== undefined) out.push({ op: 'openmenu', at: String(raw.openmenu), text: raw.text ? String(raw.text) : '', ms: raw.ms ?? 900, danger: false })
    else if (raw.text !== undefined) out.push({ op: 'text', value: String(raw.text), at: raw.at ? String(raw.at) : '', menu: raw.menu ? String(raw.menu) : '', danger })
    else if (raw.wheel !== undefined) {
      const dir = String(raw.wheel)
      if (dir !== 'up' && dir !== 'down') throw new Error('wheel 只能是 up 或 down')
      const notches = Number.isFinite(Number(raw.notches)) ? Math.max(1, Math.min(10, Math.trunc(Number(raw.notches)))) : 3
      out.push({ op: 'wheel', wheel: dir, notches, at: raw.at ? String(raw.at) : '50,50', wait: Number.isFinite(Number(raw.wait)) ? Number(raw.wait) : 400, danger })
    }
    else if (raw.key !== undefined) out.push({ op: 'key', name: String(raw.key), n: raw.n ?? 1, danger })
    else if (raw.panel !== undefined) {
      const side = String(raw.panel)
      if (side !== 'control' && side !== 'notification') throw new Error('panel 只能是 control 或 notification')
      out.push({ op: 'panel', side, danger: false })
    }
    else if (raw.back !== undefined && raw.back !== false) out.push({ op: 'back', danger: false })
    else if (raw.wait !== undefined) out.push({ op: 'wait', ms: Number(raw.wait) || 300 })
    else if (raw.clip !== undefined) out.push({ op: 'clip', value: raw.clip === true || raw.clip === 'read' ? null : String(raw.clip) })  // '@restore' 原样传给 PS 层判断
    else throw new Error(`无法识别的步骤：${JSON.stringify(raw)}`)
  }
  return out
}

// ---------------------------------------------------------------------------
// 工具定义
// ---------------------------------------------------------------------------
const TOOLS = [
  {
    name: 'phone_wake',
    description: '全后台唤起/恢复小米互联并等待真实手机画面（不点任务栏、不发 SendInput、不动鼠标、不抢焦点）。插件按「纯色 → 动态 → OCR」三套判据综合判定：每 2 秒走一套，共 5 套（10 秒）。state 含义：ready/restored/started=已解锁有真实画面；awaiting-unlock=已连上但手机锁屏，必须让主人手动指纹解锁并等确认；connect-failed=连不上（读到「加载失败」，或等满 10 秒仍是「正在连接」）；screen-not-projected=窗口在但画面空白；phone-not-found=设备不在附近或不在同一局域网。插件绝不点击锁屏、授权或配对按钮。',
    inputSchema: {
      type: 'object',
      properties: {
        timeoutMs: { type: 'integer', minimum: 3000, maximum: 60000, description: '等待小米互联/手机画面出现的最长时间，默认 15000ms' },
      },
      additionalProperties: false,
    },
    async handler(args = {}) {
      const timeoutMs = Number.isFinite(Number(args.timeoutMs)) ? Number(args.timeoutMs) : 15000
      const bounded = Math.max(3000, Math.min(60000, Math.trunc(timeoutMs)))
      const r = await run({ action: 'wake', timeoutMs: bounded }, bounded + 25000)
      // 失败：把 state / deviceState / userActionRequired / error 原样透出，
      // 调用方才能区分「设备不在场」「还在连」「连不上」「客户端缺失」。
      if (r.ok === false) {
        return {
          text: {
            ok: false,
            action: 'wake',
            state: r.state,
            deviceState: r.deviceState,
            started: !!r.started,
            restored: !!r.restored,
            unlockRequired: false,
            errorPage: r.errorPage,
            evidence: r.evidence,
            ocrAvailable: r.ocrAvailable,
            ocrHint: r.ocrHint,
            ...(r.ocrAvailable === false ? { ocrMissing: r.ocrHint } : {}),
            error: r.error,
            userActionRequired: r.userActionRequired,
          },
        }
      }
      // 成功：按真实状态透出，不能一律报 unlockRequired=true。
      return {
        text: {
          ok: true,
          action: 'wake',
          state: r.state,
          surface: r.surface,
          s: [r.screen.w, r.screen.h],
          aspect: r.aspect,
          started: !!r.started,
          restored: !!r.restored,
          unlockRequired: r.unlockRequired === true,
          unlockState: r.unlockState,
          evidence: r.evidence,
          ocrAvailable: r.ocrAvailable,
          ocrHint: r.ocrHint,
          ...(r.ocrAvailable === false ? { ocrMissing: r.ocrHint } : {}),
          userPrompt: r.userPrompt,
        },
      }
    },
  },
  {
    name: 'phone_info',
    description: '体检小米互联手机窗口：窗口是否存在、画面区像素尺寸、是否最小化。约 60 tokens，仅开头或怀疑异常时调用。',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    async handler() {
      const r = await run({ action: 'info' }, 20000)
      if (r.ok === false) return { text: { ok: false, error: r.error } }
      return { text: { ok: true, s: [r.screen.w, r.screen.h], window: { title: r.parent.title, iconic: r.parent.iconic, visible: r.parent.visible } } }
    },
  },
  {
    name: 'phone_see',
    description:
      '看小米互联手机画面（后台，不抢焦点）。只负责把画面交给你看，【不做页面状态判定】——画面是什么、该点哪里，由你自己看图判断。'
      + '默认 image:"auto" 走关键帧策略：首次/大变化/连续 8 次操作后返回带百分比标尺的全屏图；局部变化返回带全局标尺的区域图；无变化只回元数据。'
      + 'image:"full" 强制整屏，image:"region" 配合 region 强制区域图，image:"none" 只看状态。'
      + '标尺四周标注全局百分比：顶部/底部是 x%，左侧/右侧是 y%。',
    inputSchema: {
      type: 'object',
      properties: {
        image: { type: 'string', enum: ['auto', 'full', 'region', 'none'], description: 'auto=关键帧策略（默认）；full=强制整屏；region=强制区域图（需 region）；none=只要状态' },
        region: { type: 'string', description: '区域截图（百分比 "x,y,w,h"），例如 "0,50,100,20"；外圈标尺使用全屏全局百分比' },
        grid: { type: 'string', enum: ['ruler', 'off'], description: 'ruler=带百分比标尺（默认）；off=无标尺原图' },
        gridStep: { type: 'integer', enum: [10, 5], description: '全屏主刻度间隔：10（默认）或 5' },
        rulerTheme: { type: 'string', enum: ['light', 'dark', 'auto'], description: '标尺配色，默认 light' },
      },
      additionalProperties: false,
    },
    async handler(args = {}) {
      const imageMode = ['auto', 'full', 'region', 'none'].includes(args.image) ? args.image : 'auto'
      if (imageMode === 'region' && !args.region) {
        return { text: { ok: false, error: 'image:"region" 时必须提供 region（百分比 "x,y,w,h"）' } }
      }
      const req = {
        action: 'capture',
        smart: true,
        out: args.region ? REGION : FRAME,
        rawOut: FRAME_RAW,
        mode: imageMode === 'full' ? 'full' : args.region ? 'region' : 'auto',
        commit: imageMode !== 'none',
      }
      if (args.region) req.region = String(args.region).split(',').map(Number)
      if (args.grid) req.grid = String(args.grid)
      if (args.gridStep) req.gridStep = Number(args.gridStep)
      if (args.rulerTheme) req.rulerTheme = String(args.rulerTheme)
      const r = await run(req, 60000)
      if (r.ok === false) return { text: { ok: false, error: r.error } }
      const img = r.img || {}
      const s = img.screen ? [img.screen.w, img.screen.h] : [r.screen.w, r.screen.h]
      const payload = {
        ok: true,
        s,
        ch: img.changed !== false,
        mode: img.mode,
        reason: img.reason,
        frameId: img.frameId,
        expectedS: img.expectedS || s,
        out: img.out,
        contentBox: img.contentBox,
        orientation: img.orientation,
        grid: img.grid,
      }
      if (img.changeBoxPx) payload.changeBoxPx = img.changeBoxPx
      if (img.changeBoxPct) payload.changeBoxPct = img.changeBoxPct
      if (img.box) payload.box = img.box
      if (img.screen) payload.screen = [img.screen.w, img.screen.h]
      if (img.region) { payload.region = img.region; payload.coordSpace = 'screen' }
      if (img.dimensionChanged) payload.dimensionChanged = true
      if (img.diffRatio !== undefined) payload.diffRatio = img.diffRatio
      if (img.changed === false && img.mode !== 'full') payload.note = '画面未变化'
      // 这里【不做任何页面判定】：画面状态只有 phone_wake 在唤起期间才可靠。
      const wantImage = imageMode !== 'none' && (img.mode === 'full' || img.mode === 'region' || img.changed !== false)
      return { text: payload, image: wantImage && img.path && fs.existsSync(img.path) ? img.path : null }
    },
  },
  {
    name: 'phone_panel',
    description: '打开手机的系统面板（后台手势，不抢焦点）。side="control" 打开控制中心（快捷开关/亮度/音量），side="notification" 打开通知栏。关闭用 phone_back。面板已打开时会先返回再重新拉，避免叠在一起。',
    inputSchema: {
      type: 'object',
      properties: {
        side: { type: 'string', enum: ['control', 'notification'], description: 'control=控制中心（默认），notification=通知栏' },
      },
      additionalProperties: false,
    },
    async handler(args = {}) {
      const side = args.side === 'notification' ? 'notification' : 'control'
      const r = await run({ action: 'panel', side }, 30000)
      if (r.ok === false) return { text: { ok: false, error: r.error } }
      const did = r.did || {}
      return {
        text: {
          ok: true,
          action: 'panel',
          side: did.side || side,
          s: [r.screen.w, r.screen.h],
          hint: side === 'control'
            ? '控制中心已打开。关闭用 phone_back。'
            : '通知栏已打开。关闭用 phone_back。',
        },
      }
    },
  },
  {
    name: 'phone_back',
    description: '执行系统返回手势（从右边缘往左滑，后台，不抢焦点）。用于：关闭通知栏/控制中心、App 内返回上一页。相当于按手机的返回键/返回手势。',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    async handler() {
      const r = await run({ action: 'back' }, 30000)
      if (r.ok === false) return { text: { ok: false, error: r.error } }
      return { text: { ok: true, action: 'back', s: [r.screen.w, r.screen.h] } }
    },
  },
  {
    name: 'phone_do',
    description:
      '在小米互联手机上批量执行动作（后台）。steps 支持 tap/swipe/wheel/longpress/text/key/wait/clip/panel/back，坐标为画面区百分比。'
      + '滚动优先用 {"wheel":"down","notches":3,"at":"50,60","wait":400}（WM_MOUSEWHEEL 透传，无惯性、不移动真实鼠标）；swipe 只在滚轮不可用时兜底。'
      + '一次调用可串多步，执行完按关键帧策略返回整屏或带全局标尺的区域图。',
    inputSchema: {
      type: 'object',
      properties: {
        openmenu: { type: 'string', description: '中文输入第一步：输入框位置 "x,y"。写剪贴板→长按→把弹出的菜单裁成图片返回（不点击任何菜单项）。看着图确认「粘贴」在哪，再用 tap 点它，最后 clip:"@restore" 还原剪贴板。' },
        text: { type: 'string', description: '配合 openmenu 使用：要粘贴的中文内容。' },
        steps: {
          type: 'array',
          description: '动作列表，例：[{"tap":"50,88"},{"wheel":"down","notches":3,"at":"50,60","wait":400},{"wait":500}]。wheel 的 up/down 对应正/负 120 delta，notches 建议 ≤10；text 含中文必须给 at（输入框位置）；key 支持 backspace/enter/esc/tab/delete/space，n 为次数。',
          items: { type: 'object', additionalProperties: true },
        },
        image: { type: 'string', enum: ['auto', 'full', 'none'], description: 'auto=关键帧策略（默认）；full=强制整屏；none=只要回执' },
        grid: { type: 'string', enum: ['ruler', 'off'], description: 'ruler=返回图带标尺（默认）；off=无标尺原图（内部 verify 始终用原图）' },
        gridStep: { type: 'integer', enum: [10, 5], description: '全屏主刻度间隔：10（默认）或 5' },
        rulerTheme: { type: 'string', enum: ['light', 'dark', 'auto'], description: '标尺配色，默认 light' },
        verify: { type: 'string', description: '点击验证区域（百分比 "x,y,w,h"）：只比无标尺原图这块是否真变了，没变自动重试一次，返回 hit/tries/banner/verifyDiffPx' },
        expectedS: { type: 'array', items: { type: 'integer' }, minItems: 2, maxItems: 2, description: '预期画面尺寸 [W,H]；当前尺寸不符返回 stale_frame 并拒绝执行，防止旋转后旧坐标误点' },
        frameId: { type: 'string', description: '可选：截图返回的 frameId；尺寸不一致时拒绝执行' },
        confirm: { type: 'boolean', description: '用户已明确同意时才传 true' },
      },
      additionalProperties: false,
    },
    async handler(args = {}) {
      if (typeof args.openmenu === 'string' && args.openmenu.length > 0) {
        const r = await run({ action: 'openmenu', at: String(args.openmenu), text: args.text ? String(args.text) : '', ms: 900 }, 45000)
        if (r.ok === false) return { text: { ok: false, error: r.error } }
        const did = r.did || {}
        return {
          text: { ok: true, opened: did.opened, box: did.box, crop: did.crop, hint: did.hint },
          image: did.crop && fs.existsSync(did.crop) ? did.crop : null,
        }
      }
      let steps
      try {
        steps = normalizeSteps(args.steps)
      } catch (e) {
        return { text: { ok: false, error: e.message } }
      }
      if (!steps.length) return { text: { ok: false, error: 'steps 为空' } }
      const blocked = gate(steps, args.confirm === true)
      if (blocked) {
        blocked.hint = '先向用户说明并取得同意，再带 confirm:true 调用'
        return { text: { ok: false, ...blocked } }
      }
      const wantCapture = args.image !== 'none' || !!args.verify
      const req = {
        action: 'batch',
        steps,
        capture: wantCapture,
        out: FRAME,
        rawOut: FRAME_RAW,
        mode: args.image === 'full' ? 'full' : 'auto',
        image: args.image || 'auto',
        commit: args.image !== 'none',
      }
      if (args.grid) req.grid = String(args.grid)
      if (args.gridStep) req.gridStep = Number(args.gridStep)
      if (args.rulerTheme) req.rulerTheme = String(args.rulerTheme)
      if (Array.isArray(args.expectedS) && args.expectedS.length === 2) req.expectedS = args.expectedS.map(Number)
      else if (typeof args.expectedS === 'string' && args.expectedS.includes(',')) {
        const pair = args.expectedS.split(',').map(Number)
        if (pair.length === 2 && pair.every((n) => !Number.isNaN(n))) req.expectedS = pair
      }
      if (args.frameId) req.frameId = String(args.frameId)
      if (args.verify) {
        const rect = String(args.verify).split(',').map(Number)
        if (rect.length === 4 && rect.every((n) => !Number.isNaN(n))) { req.verify = rect; req.retry = true }
      }
      const r = await run(req, 120000)
      if (r.ok === false) {
        if (r.stale) {
          return {
            text: {
              ok: false, stale: true, state: 'stale_frame', error: 'stale_frame',
              reason: r.reason, expectedS: r.expectedS, s: r.s,
            },
          }
        }
        return { text: { ok: false, error: r.error } }
      }
      const img = r.img || {}
      const s = img.screen ? [img.screen.w, img.screen.h] : [r.screen.w, r.screen.h]
      const payload = { ok: true, s, did: (r.steps || []).length }
      if (r.hit !== undefined) payload.hit = r.hit
      if (r.tries > 1) payload.tries = r.tries
      if (r.banner) payload.banner = true
      if (r.verifyDiffPx !== undefined) payload.verifyDiffPx = r.verifyDiffPx
      if (r.scrolled !== undefined) {
        payload.scrolled = r.scrolled
        payload.atEdge = r.atEdge
        payload.notScrollable = r.notScrollable
        if (r.wheel) payload.wheel = r.wheel
      }
      // 中文粘贴的成败要浮到顶层，别让人去翻 steps 日志
      const textSteps = (r.steps || []).filter((s2) => s2.op === 'text')
      if (textSteps.length) {
        payload.text = textSteps.map((s2) => ({ n: s2.n, mode: s2.mode, inserted: s2.inserted, menu: s2.menu }))
        if (textSteps.some((s2) => s2.inserted === false)) payload.textFailed = true
      }
      if (r.img) {
        payload.ch = img.changed !== false
        payload.mode = img.mode
        payload.reason = img.reason
        payload.frameId = img.frameId
        payload.expectedS = img.expectedS || s
        payload.out = img.out
        payload.contentBox = img.contentBox
        payload.orientation = img.orientation
        payload.grid = img.grid
        if (img.changeBoxPx) payload.changeBoxPx = img.changeBoxPx
        if (img.changeBoxPct) payload.changeBoxPct = img.changeBoxPct
        if (img.box) payload.box = img.box
        if (img.screen) payload.screen = [img.screen.w, img.screen.h]
        if (img.dimensionChanged) payload.dimensionChanged = true
        if (img.changed === false && img.mode !== 'full') payload.note = '画面未变化（点击可能没生效）'
      }
      const wantImage = args.image !== 'none' && !!img.path && (img.mode === 'full' || img.changed !== false)
      return { text: payload, image: wantImage ? img.path : null }
    },
  },
]

// ---------------------------------------------------------------------------
// JSON-RPC / MCP
// ---------------------------------------------------------------------------
const TOOL_BY_NAME = new Map(TOOLS.map((t) => [t.name, t]))

function rpcError(id, code, message) {
  return { jsonrpc: '2.0', id, error: { code, message } }
}

async function handleCall(id, params) {
  const tool = TOOL_BY_NAME.get(params?.name)
  if (!tool) return rpcError(id, -32602, `Unknown tool: ${params?.name}`)
  let res
  try {
    res = await tool.handler(params.arguments || {})
  } catch (e) {
    return { jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: JSON.stringify({ ok: false, error: e.message }) }] } }
  }
  const content = [{ type: 'text', text: JSON.stringify(res.text) }]
  if (res.image && fs.existsSync(res.image)) {
    try {
      const data = fs.readFileSync(res.image).toString('base64')
      content.push({ type: 'image', data, mimeType: 'image/png' })
    } catch {
      /* 图片读失败就只回文本 */
    }
  }
  return { jsonrpc: '2.0', id, result: { content } }
}

async function dispatch(msg) {
  const { id, method, params } = msg || {}
  if (method === 'initialize') {
    return {
      jsonrpc: '2.0',
      id,
      result: {
        protocolVersion: params?.protocolVersion || MCP_PROTOCOL_VERSION,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'dsh-phone-use', version: SERVER_VERSION },
      },
    }
  }
  if (method === 'notifications/initialized' || method === 'initialized') return null
  if (method === 'ping') return { jsonrpc: '2.0', id, result: {} }
  if (method === 'tools/list') {
    return {
      jsonrpc: '2.0',
      id,
      result: { tools: TOOLS.map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })) },
    }
  }
  if (method === 'tools/call') return await handleCall(id, params)
  if (method === 'shutdown') { setTimeout(() => process.exit(0), 10); return { jsonrpc: '2.0', id, result: null } }
  return rpcError(id, -32601, `Method not found: ${method}`)
}

let framingMode = 'line'
function send(message) {
  if (!message) return
  const payload = JSON.stringify(message)
  if (framingMode === 'headers') {
    process.stdout.write(`Content-Length: ${Buffer.byteLength(payload, 'utf8')}\r\n\r\n${payload}`)
  } else {
    process.stdout.write(`${payload}\n`)
  }
}

let buffer = Buffer.alloc(0)
function ingest(chunk) {
  buffer = Buffer.concat([buffer, chunk])
  for (;;) {
    if (buffer.length === 0) return
    const asText = buffer.toString('utf8')
    if (asText.startsWith('Content-Length:')) {
      framingMode = 'headers'
      const headerEnd = asText.indexOf('\r\n\r\n')
      if (headerEnd === -1) return
      const match = /Content-Length:\s*(\d+)/i.exec(asText.slice(0, headerEnd))
      if (!match) { buffer = Buffer.alloc(0); return }
      const length = Number(match[1])
      const bodyStart = headerEnd + 4
      if (buffer.length < bodyStart + length) return
      const body = buffer.subarray(bodyStart, bodyStart + length).toString('utf8')
      buffer = buffer.subarray(bodyStart + length)
      void onMessage(body)
      continue
    }
    const newline = asText.indexOf('\n')
    if (newline === -1) return
    const line = asText.slice(0, newline).trim()
    buffer = buffer.subarray(Buffer.byteLength(asText.slice(0, newline + 1), 'utf8'))
    if (line) void onMessage(line)
  }
}

async function onMessage(raw) {
  let msg
  try {
    msg = JSON.parse(raw)
  } catch {
    return
  }
  const reply = await dispatch(msg)
  if (reply) send(reply)
}

process.stdin.on('data', ingest)
process.stdin.on('error', () => {})
process.on('uncaughtException', (e) => {
  process.stderr.write(`dsh-phone-use mcp: ${e?.stack || e}\n`)
})
process.on('unhandledRejection', (e) => {
  process.stderr.write(`dsh-phone-use mcp rejection: ${e?.stack || e}\n`)
})

// --self-test：不连宿主，直接跑一遍工具，便于排查
if (process.argv.includes('--self-test')) {
  const info = await TOOLS[0].handler({})
  process.stdout.write(JSON.stringify({ selfTest: true, info: info.text }) + '\n')
  process.exit(0)
}
