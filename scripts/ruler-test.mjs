// 标尺合成测试：不连接手机，直接按 372×844 / 1080×2400 / 1127×642 画标尺并自检。
// 用法：node scripts/ruler-test.mjs
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const PKG_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const SCRIPT = path.join(PKG_DIR, 'scripts', 'phone.ps1')
const BASE = path.join(os.tmpdir(), 'dsh-phone-use')
const OUT = path.join(BASE, 'ruler-test')

fs.mkdirSync(BASE, { recursive: true })

function run(req, timeoutMs = 120000) {
  const reqFile = path.join(BASE, `ruler-req-${Date.now()}.json`)
  const resFile = path.join(BASE, `ruler-res-${Date.now()}.json`)
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
      try {
        resolve(JSON.parse(fs.readFileSync(resFile, 'utf8')))
      } catch {
        resolve({ ok: false, error: err.trim().split(/\r?\n/).slice(-3).join(' | ') || '无结果' })
      } finally {
        try { fs.unlinkSync(reqFile) } catch {}
        try { fs.unlinkSync(resFile) } catch {}
      }
    })
  })
}

const sizes = [[372, 844], [1080, 2400], [1127, 642]]
const r = await run({ action: 'ruler-test', sizes, outDir: OUT })
if (r.ok === false) {
  console.error(`[FAIL] ruler-test: ${r.error}`)
  process.exit(1)
}
let failed = 0
for (const item of r.items || []) {
  const [w, h] = item.size
  const fullOut = item.fullOut
  const diff = item.contentDiffPixels || {}
  const okSize = fullOut[0] === w + 2 * item.margin && fullOut[1] === h + 2 * item.margin
  const okDiff = diff.full === 0 && diff.region === 0
  if (!okSize || !okDiff) failed++
  console.log(`${okSize && okDiff ? '[OK]  ' : '[FAIL]'} ${w}x${h} margin=${item.margin} font=${item.font} out=${fullOut.join('x')} contentDiff=${JSON.stringify(diff)}`)
  console.log(`        full:   ${item.full}`)
  console.log(`        region: ${item.region}`)
  console.log(`        row:    ${item.regionRow}`)
}
process.exit(failed ? 1 : 0)
