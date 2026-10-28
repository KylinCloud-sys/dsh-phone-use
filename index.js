// dsh-mi-phone-use — DSH 插件入口
//
// 与 dsh-computer-use-win 同样的挂载方式：本文件只做两件事
//   1. 注册技能 mi-phone（技能是 DSH 原生能力，MCP server 注册不了）
//   2. 通过 @deepseek-ai/dsh-mcp-client 把 mcp/server.mjs 作为 stdio MCP 服务挂上
// 工具由宿主注入，名字形如 mcp__miphone__phone_info，每个会话都有。

import { fileURLToPath } from 'node:url'
import { mkdtempSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { SKILL_CONTENT } from './skill-content.mjs'

export const name = 'mi-phone-use'
export const inject = ['tools']

const SERVER = fileURLToPath(new URL('./mcp/server.mjs', import.meta.url))

export function bridgeConfig() {
  const root = mkdtempSync(path.join(os.tmpdir(), 'dsh-mi-phone-use-'))
  return {
    serverName: 'miphone',
    transport: 'stdio',
    command: process.execPath,
    args: [SERVER],
    env: {
      ELECTRON_RUN_AS_NODE: '1',
      MI_PHONE_TMP: root,
    },
    toolCallTimeoutMs: 120000,
    failOnStartupError: false,
  }
}

export async function apply(ctx) {
  // 1) 技能
  const skills = typeof ctx.get === 'function' ? ctx.get('skills') : undefined
  if (skills && typeof skills.register === 'function') {
    try {
      skills.register({
        name: 'mi-phone',
        title: '小米互联手机操控 · 后台点按与输入',
        description:
          '通过小米互联（跨屏协作）在后台操控手机：截图、按百分比点击/滑动、输入中英文。' +
          '含硬规则：只用互联不打 adb、全后台不抢焦点、未经许可不发消息不下单、失败即停、全局键盘注入需先征得同意。',
        whenToUse:
          '用户要求操作手机（打开某个 App、点某个按钮、发消息、截图看手机屏幕、在手机上输入文字）时使用；' +
          '需要看手机当前画面、或要连续点按好几下时也用它。',
        source: 'dsh-mi-phone-use',
        content: SKILL_CONTENT,
      })
    } catch (error) {
      ctx.logger?.warn?.('dsh-mi-phone-use: 技能注册失败：%s', error?.message || error)
    }
  }

  // 2) MCP 桥接
  let bridge
  try {
    bridge = await import('@deepseek-ai/dsh-mcp-client')
  } catch (error) {
    ctx.logger?.error?.(
      'dsh-mi-phone-use: 缺少 @deepseek-ai/dsh-mcp-client，手机工具不可用：%s',
      error?.message || error,
    )
    return
  }
  const config = bridgeConfig()
  ctx.logger?.info?.('dsh-mi-phone-use: 挂载 MCP server（serverName=%s）', config.serverName)
  const connection = ctx.plugin(bridge, config)
  await connection
}
