// MCP server 握手测试：模拟宿主，走标准 JSON-RPC 行协议
import { spawn } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const server = path.join(here, '..', 'mcp', 'server.mjs')

const child = spawn(process.execPath, [server], { stdio: ['pipe', 'pipe', 'pipe'] })
let buf = ''
const pending = new Map()

child.stdout.on('data', (chunk) => {
  buf += chunk.toString('utf8')
  let i
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim()
    buf = buf.slice(i + 1)
    if (!line) continue
    try {
      const msg = JSON.parse(line)
      if (msg.id !== undefined && pending.has(msg.id)) {
        pending.get(msg.id)(msg)
        pending.delete(msg.id)
      }
    } catch {
      /* 忽略非 JSON 行 */
    }
  }
})
child.stderr.on('data', (d) => process.stderr.write(`[server] ${d}`))

let seq = 0
function call(method, params) {
  const id = ++seq
  return new Promise((resolve, reject) => {
    pending.set(id, resolve)
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
    setTimeout(() => reject(new Error(`${method} 超时`)), 60000)
  })
}

const init = await call('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'test', version: '1' } })
console.log('initialize:', JSON.stringify(init.result))

child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n')

const list = await call('tools/list', {})
console.log('tools:', list.result.tools.map((t) => t.name).join(', '))

const info = await call('tools/call', { name: 'phone_info', arguments: {} })
const text = info.result.content.find((c) => c.type === 'text')?.text
console.log('phone_info:', text)

const see = await call('tools/call', { name: 'phone_see', arguments: {} })
const seeText = see.result.content.find((c) => c.type === 'text')?.text
const hasImage = see.result.content.some((c) => c.type === 'image')
console.log('phone_see:', seeText, '| 带图:', hasImage)

child.stdin.end()
child.kill()
