#!/usr/bin/env node
// 会话无关的 CLI：技能加载后即可用，不依赖 phone_* 工具是否被投影进当前会话。
//
// 用法：
//   node cli.mjs wake
//   node cli.mjs info
//   node cli.mjs see [--full] [--region 0,60,100,40]
//   node cli.mjs do '{"steps":[{"tap":"50,88"},{"wait":500}]}'
//   node cli.mjs do --file steps.json --verify 0,10,100,70 --confirm
//
// 输出永远是紧凑 JSON；需要看图时输出 png 路径（配合 read_image）。

import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const PKG_DIR = path.dirname(fileURLToPath(import.meta.url))
const SCRIPT = path.join(PKG_DIR, 'scripts', 'phone.ps1')
const BASE = path.join(os.tmpdir(), 'dsh-phone-use')
const CONFIG_FILE = path.join(PKG_DIR, 'config.json')

fs.mkdirSync(BASE, { recursive: true })

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
  if (cfg.invertWheel === true) req = { ...req, invertWheel: true }
  const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
  const reqFile = path.join(BASE, `cli-req-${id}.json`)
  const resFile = path.join(BASE, `cli-res-${id}.json`)
  fs.writeFileSync(reqFile, JSON.stringify(req), 'utf8')
  return new Promise((resolve) => {
    const child = spawn('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', SCRIPT, '-RequestFile', reqFile, '-ResultFile', resFile,
    ], { windowsHide: true })
    let err = ''
    child.stderr.on('data', (d) => { err += String(d) })
    const timer = setTimeout(() => { try { child.kill() } catch {} }, timeoutMs)
    child.on('close', () => {
      clearTimeout(timer)
      let out
      try {
        out = JSON.parse(fs.readFileSync(resFile, 'utf8'))
      } catch {
        out = { ok: false, error: err.trim().split('\n').slice(-3).join(' | ') || '执行器无结果' }
      }
      try { fs.unlinkSync(reqFile) } catch {}
      try { fs.unlinkSync(resFile) } catch {}
      resolve(out)
    })
  })
}

/** 权限闸门：与工具版同一套规则 */
function gate(steps) {
  const cfg = readConfig()
  const mode = ['full', 'auto', 'ask'].includes(cfg.permission) ? cfg.permission : 'auto'
  const zones = Array.isArray(cfg.dangerZones) ? cfg.dangerZones : []
  const confirmFlag = process.argv.includes('--confirm')
  if (confirmFlag || mode === 'full') return null
  if (mode === 'ask') return { need: 'confirm', mode, reason: 'ask 模式：写操作需要显式确认' }
  for (const s of steps) {
    if (s.danger) return { need: 'confirm', mode, reason: '该步骤被标记为危险操作' }
    const at = s.at || s.tap || s.longpress
    if (at) {
      const [x, y] = String(at).split(',').map(Number)
      for (const z of zones) {
        const r = z && z.rect
        if (!r || r.length < 4) continue
        if (x >= r[0] && x <= r[0] + r[2] && y >= r[1] && y <= r[1] + r[3]) {
          return { need: 'confirm', mode, reason: `命中危险区域「${z.label || '未命名'}」`, at }
        }
      }
    }
  }
  return null
}

/** 把紧凑写法翻译成执行器步骤 */
function normalize(steps) {
  const out = []
  for (const raw of steps) {
    if (raw.op) { out.push(raw); continue }
    const danger = raw.danger === true
    if (raw.tap !== undefined) out.push({ op: 'tap', at: String(raw.tap), danger })
    else if (raw.swipe !== undefined) {
      const [from, to] = String(raw.swipe).split('>').map((s) => s.trim())
      out.push({ op: 'swipe', from, to, ms: raw.ms ?? 300, danger })
    } else if (raw.longpress !== undefined) out.push({ op: 'longpress', at: String(raw.longpress), ms: raw.ms ?? 800, danger })
    else if (raw.openmenu !== undefined) out.push({ op: 'openmenu', at: String(raw.openmenu), text: raw.text ? String(raw.text) : '', ms: raw.ms ?? 900 })
    else if (raw.text !== undefined) out.push({ op: 'text', value: String(raw.text), at: raw.at ? String(raw.at) : '', menu: raw.menu ? String(raw.menu) : '', danger })
    else if (raw.wheel !== undefined) {
      const dir = String(raw.wheel)
      if (dir !== 'up' && dir !== 'down') throw new Error('wheel 只能是 up 或 down')
      const notches = Number.isFinite(Number(raw.notches)) ? Math.max(1, Math.min(10, Math.trunc(Number(raw.notches)))) : 3
      out.push({ op: 'wheel', wheel: dir, notches, at: raw.at ? String(raw.at) : '50,50', wait: Number.isFinite(Number(raw.wait)) ? Number(raw.wait) : 400, danger })
    }
    else if (raw.key !== undefined) out.push({ op: 'key', name: String(raw.key), n: raw.n ?? 1, danger })
    else if (raw.wait !== undefined) out.push({ op: 'wait', ms: Number(raw.wait) || 300 })
    else if (raw.clip !== undefined) out.push({ op: 'clip', value: raw.clip === true || raw.clip === 'read' ? null : String(raw.clip) })
    else throw new Error(`无法识别的步骤：${JSON.stringify(raw)}`)
  }
  return out
}

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n')
}

const [cmd, ...rest] = process.argv.slice(2)

function flagValue(name) {
  const i = rest.indexOf(name)
  return i >= 0 ? rest[i + 1] : undefined
}

if (cmd === 'wake') {
  const rawTimeout = Number(flagValue('--timeout') || 15000)
  const timeoutMs = Math.max(3000, Math.min(60000, Number.isFinite(rawTimeout) ? Math.trunc(rawTimeout) : 15000))
  const r = await run({ action: 'wake', timeoutMs }, timeoutMs + 15000)
  emit(r)
} else if (cmd === 'info') {
  const r = await run({ action: 'info' }, 20000)
  emit(r.ok === false ? { ok: false, error: r.error } : {
    ok: true,
    s: [r.screen.w, r.screen.h],
    window: { title: r.parent.title, iconic: r.parent.iconic, visible: r.parent.visible },
  })
} else if (cmd === 'see') {
  const out = path.join(BASE, `cli-see-${Date.now()}.png`)
  const region = flagValue('--region')
  const mode = region ? 'region' : rest.includes('--full') ? 'full' : 'auto'
  const req = {
    action: 'capture', smart: true, out, rawOut: path.join(BASE, 'last.raw.png'), mode,
    commit: true, grid: 'ruler',
  }
  if (region) req.region = region.split(',').map(Number)
  const r = await run(req, 60000)
  if (r.ok === false) { emit({ ok: false, error: r.error }); process.exit(0) }
  const img = r.img || {}
  const s = img.screen ? [img.screen.w, img.screen.h] : [r.screen.w, r.screen.h]
  const payload = { ok: true, s, ch: img.changed !== false, mode: img.mode, reason: img.reason, frameId: img.frameId, expectedS: img.expectedS, out: img.out, contentBox: img.contentBox }
  if (img.changeBoxPx) payload.changeBoxPx = img.changeBoxPx
  if (img.changeBoxPct) payload.changeBoxPct = img.changeBoxPct
  if (img.region) { payload.region = img.region; payload.coordSpace = 'screen' }
  if (img.changed === false && img.mode !== 'full') payload.note = '画面未变化'
  payload.path = img.path || out
  emit(payload)
} else if (cmd === 'do') {
  let spec
  try {
    const file = flagValue('--file')
    spec = file ? JSON.parse(fs.readFileSync(file, 'utf8')) : JSON.parse(rest[0] || '{}')
    if (Array.isArray(spec)) spec = { steps: spec }
  } catch (e) {
    emit({ ok: false, error: `步骤 JSON 解析失败：${e.message}` }); process.exit(0)
  }
  const steps = normalize(spec.steps || [])
  if (!steps.length) { emit({ ok: false, error: 'steps 为空' }); process.exit(0) }
  const blocked = gate(steps)
  if (blocked) {
    blocked.hint = '取得用户同意后加 --confirm 重跑'
    emit({ ok: false, ...blocked }); process.exit(0)
  }
  const out = path.join(BASE, `cli-do-${Date.now()}.png`)
  const req = {
    action: 'batch', steps, capture: true, out,
    rawOut: path.join(BASE, 'last.raw.png'),
    mode: flagValue('--full') ? 'full' : 'auto', grid: 'ruler',
  }
  if (spec.expectedS) req.expectedS = spec.expectedS
  if (spec.grid) req.grid = String(spec.grid)
  if (spec.rulerTheme) req.rulerTheme = String(spec.rulerTheme)
  const v = flagValue('--verify')
  if (v) { req.verify = v.split(',').map(Number); req.retry = true }
  const r = await run(req, 120000)
  if (r.ok === false) { emit({ ok: false, error: r.error, stale: r.stale, reason: r.reason }); process.exit(0) }
  const img = r.img || {}
  const s = img.screen ? [img.screen.w, img.screen.h] : [r.screen.w, r.screen.h]
  const payload = { ok: true, s, did: (r.steps || []).length }
  if (r.hit !== undefined) payload.hit = r.hit
  if (r.tries > 1) payload.tries = r.tries
  if (r.banner) payload.banner = true
  if (r.verifyDiffPx !== undefined) payload.verifyDiffPx = r.verifyDiffPx
  if (r.scrolled !== undefined) { payload.scrolled = r.scrolled; payload.atEdge = r.atEdge; payload.notScrollable = r.notScrollable }
  if (r.img) {
    payload.ch = img.changed !== false
    payload.mode = img.mode
    payload.reason = img.reason
    payload.frameId = img.frameId
    payload.expectedS = img.expectedS
    payload.out = img.out
    payload.contentBox = img.contentBox
    if (img.changeBoxPx) payload.changeBoxPx = img.changeBoxPx
    if (img.changeBoxPct) payload.changeBoxPct = img.changeBoxPct
    if (img.changed === false && img.mode !== 'full') payload.note = '画面未变化（点击可能没生效）'
    payload.path = img.path || out
  }
  emit(payload)
} else {
  emit({
    ok: false,
    error: '用法: node cli.mjs info | see [--full] [--region x,y,w,h] | do \'{"steps":[...]}\' [--verify x,y,w,h] [--confirm]',
  })
  process.exit(1)
}
