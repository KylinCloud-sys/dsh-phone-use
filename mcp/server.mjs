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
 * 固定帧文件：截图与差分歧都用这一个路径。
 * PowerShell 侧是「先读 prev 做差分、再把新帧写到 out」，所以 prev === out 是安全的，
 * 好处是永远只有 last.png 一个文件，不会越积越多。
 */
const FRAME = path.join(BASE, 'last.png')
const CROP = path.join(BASE, 'last.crop.png')

/** 启动时清掉历史遗留（旧版本按时间戳命名的截图等），只留基线帧 */
function sweep() {
  try {
    for (const name of fs.readdirSync(BASE)) {
      if (name === 'last.png' || name === 'last.crop.png' || name === 'plugin-boot.log') continue
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
    if ((s.op === 'tap' || s.op === 'longpress') && s.at) {
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
    description: '看小米互联手机画面（后台，不抢焦点）。返回画面区尺寸与是否变化；有变化才带图。region 可只看一块（百分比 "x,y,w,h"），没变化时不返回图片。',
    inputSchema: {
      type: 'object',
      properties: {
        image: { type: 'string', enum: ['auto', 'full', 'none'], description: 'auto=有变化才给图（默认）；full=强制整屏；none=只要状态' },
        region: { type: 'string', description: '只看一块，百分比 "x,y,w,h"，例如 "0,60,100,40"' },
      },
      additionalProperties: false,
    },
    async handler(args = {}) {
      const req = { action: 'capture', out: FRAME }
      if (fs.existsSync(FRAME) && !args.region) req.prev = FRAME
      if (args.region) req.region = String(args.region).split(',').map(Number)
      const r = await run(req, 40000)
      if (r.ok === false) return { text: { ok: false, error: r.error } }
      const img = r.img || {}
      const blank = img.blank === true
      const unchanged = img.changed === false && !args.region
      const payload = { ok: true, s: [r.screen.w, r.screen.h], ch: img.changed !== false }
      if (img.changed !== false && img.box) payload.box = img.box
      if (blank) {
        payload.blank = true
        payload.state = 'screen-not-projected'
        payload.note = '画面是空白：投屏通道没建立（手机可能不在同一局域网/未开启互联），此时不需要指纹解锁。'
      } else if (unchanged) {
        payload.note = '画面未变化'
      }
      const file = args.image === 'full' ? FRAME : img.cropPath || FRAME
      const wantImage = args.image !== 'none' && !unchanged && !blank
      return { text: payload, image: wantImage ? file : null }
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
    description: '在小米互联手机上批量执行动作（后台）。steps 支持 tap/swipe/longpress/text/key/wait/clip/panel/back，坐标为画面区百分比。一次调用可串多步，执行完自动截图并按变化量返回裁图。',
    inputSchema: {
      type: 'object',
      properties: {
        openmenu: { type: 'string', description: '中文输入第一步：输入框位置 "x,y"。写剪贴板→长按→把弹出的菜单裁成图片返回（不点击任何菜单项）。看着图确认「粘贴」在哪，再用 tap 点它，最后 clip:"@restore" 还原剪贴板。' },
        text: { type: 'string', description: '配合 openmenu 使用：要粘贴的中文内容。' },
        steps: {
          type: 'array',
          description: '动作列表，例：[{"tap":"50,88"},{"wait":500},{"text":"你好","at":"40,96"}]。text 含中文必须给 at（输入框位置）；key 支持 backspace/enter/esc/tab/delete/space，n 为次数。',
          items: { type: 'object', additionalProperties: true },
        },
        image: { type: 'string', enum: ['auto', 'none'], description: 'auto=执行后回图（默认）；none=只要回执' },
        verify: { type: 'string', description: '点击验证区域（百分比 "x,y,w,h"）：只比这块是否真变了，没变自动重试一次，返回 hit/tries/banner' },
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
      const req = { action: 'batch', steps, capture: args.image !== 'none', out: FRAME }
      if (fs.existsSync(FRAME)) req.prev = FRAME
      if (args.verify) {
        const rect = String(args.verify).split(',').map(Number)
        if (rect.length === 4 && rect.every((n) => !Number.isNaN(n))) { req.verify = rect; req.retry = true }
      }
      const r = await run(req, 90000)
      if (r.ok === false) return { text: { ok: false, error: r.error } }
      const payload = { ok: true, s: [r.screen.w, r.screen.h], did: (r.steps || []).length }
      if (r.hit !== undefined) payload.hit = r.hit
      if (r.tries > 1) payload.tries = r.tries
      if (r.banner) payload.banner = true
      // 中文粘贴的成败要浮到顶层，别让人去翻 steps 日志
      const textSteps = (r.steps || []).filter((s) => s.op === 'text')
      if (textSteps.length) {
        payload.text = textSteps.map((s) => ({ n: s.n, mode: s.mode, inserted: s.inserted, menu: s.menu }))
        if (textSteps.some((s) => s.inserted === false)) payload.textFailed = true
      }
      if (r.img) {
        payload.ch = r.img.changed !== false
        if (r.img.changed !== false && r.img.box) payload.box = r.img.box
        if (r.img.changed === false) payload.note = '画面未变化（点击可能没生效）'
      }
      const wantImage = args.image !== 'none' && r.img && r.img.changed !== false
      const file = r.img?.cropPath || FRAME
      return { text: payload, image: wantImage ? file : null }
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
