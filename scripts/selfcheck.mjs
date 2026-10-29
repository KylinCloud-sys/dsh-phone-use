// 环境自检：换机器/装好后先跑这个，确认插件在这台机器上能用
// 用法： node scripts/selfcheck.mjs
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const PKG_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const SCRIPT = path.join(PKG_DIR, 'scripts', 'phone.ps1')

function run(action, extra = {}, timeoutMs = 30000) {
  const dir = path.join(os.tmpdir(), 'dsh-phone-use')
  fs.mkdirSync(dir, { recursive: true })
  const reqFile = path.join(dir, `sc-req-${Date.now()}.json`)
  const resFile = path.join(dir, `sc-res-${Date.now()}.json`)
  fs.writeFileSync(reqFile, JSON.stringify({ action, ...extra }), 'utf8')
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
        resolve({ ok: false, error: err.trim().split('\n').slice(-3).join(' | ') || '无结果文件' })
      } finally {
        try { fs.unlinkSync(reqFile) } catch {}
        try { fs.unlinkSync(resFile) } catch {}
      }
    })
  })
}

const line = (ok, label, detail = '') =>
  console.log(`${ok ? '  [OK]  ' : '  [FAIL]'} ${label}${detail ? ' — ' + detail : ''}`)

console.log(`dsh-phone-use 自检`)
console.log(`插件目录: ${PKG_DIR}`)
console.log(`Node: ${process.version}  PowerShell: ${process.env.PSModulePath ? 'ok' : '?'}`)
console.log('')

console.log('1) 窗口定位')
const info = await run('info')
if (info.ok) {
  line(true, '找到小米互联窗口', `${info.parent.title} (${info.parent.cls})`)
  line(true, '画面区', `${info.screen.w}x${info.screen.h} @ ${info.screen.x},${info.screen.y}`)
  line(!info.parent.iconic, '窗口未最小化')
} else {
  line(false, '窗口定位失败', info.error)
  console.log('\n请先打开小米互联（跨屏协作）并投出手机画面，再跑一次。')
  process.exit(1)
}

console.log('\n2) 截图')
const cap = await run('capture', { out: path.join(os.tmpdir(), 'dsh-phone-use', 'selfcheck.png') })
if (cap.ok && cap.img?.path) {
  const size = fs.statSync(cap.img.path).size
  line(true, '截图成功', `${cap.img.w}x${cap.img.h}, ${Math.round(size / 1024)}KB`)
  console.log(`      ${cap.img.path}`)
} else {
  line(false, '截图失败', cap.error)
}

console.log('\n3) 后台点击（点画面中心，应无副作用）')
const tap = await run('batch', {
  steps: [{ op: 'tap', at: '50,50' }, { op: 'wait', ms: 300 }],
  capture: true,
  out: path.join(os.tmpdir(), 'dsh-phone-use', 'selfcheck-tap.png'),
})
line(tap.ok === true, '后台点击已执行', tap.ok ? '' : tap.error)

console.log('\n4) 点击验证（verify）')
const ver = await run('batch', {
  steps: [{ op: 'tap', at: '50,50' }, { op: 'wait', ms: 300 }],
  capture: true,
  verify: [0, 0, 100, 100],
  out: path.join(os.tmpdir(), 'dsh-phone-use', 'selfcheck-verify.png'),
})
line(ver.hit !== undefined, 'verify 可用', `hit=${ver.hit} tries=${ver.tries ?? 1} banner=${ver.banner ?? false}`)

console.log('\n5) 配置文件')
const cfgPath = path.join(PKG_DIR, 'config.json')
if (fs.existsSync(cfgPath)) {
  try {
    const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'))
    line(true, 'config.json 可读', `permission=${cfg.permission ?? 'auto(默认)'}`)
  } catch (e) {
    line(false, 'config.json 解析失败', e.message)
  }
} else {
  line(true, '没有 config.json', '使用默认 permission=auto')
}

console.log('\n自检结束。全部 OK 就可以直接用了。')
