# CHANGELOG

## 0.3.0 — 2026-10-28

- **修复中文输入**：长按期间补 MOVE 心跳（只 DOWN→睡→UP 会被当成普通点击，菜单不弹）。
- 粘贴菜单改为**自动定位**：长按前后差分找弹出浮层，取最宽横向条带当菜单本体，点其中心；不再依赖写死的 `11,93`。
- 菜单抓取最多重试 3 轮（带动画弹出，抓太早会只测到光标拖柄）。
- 剪贴板同步等待 0.9s → 1.5s，避免菜单里没有「粘贴」项。
- 新增粘贴结果校验 `inserted`，`false` 表示文字没进输入框；batch 日志同步输出 `menu/menuAt/inserted/box`。
- 新增 `phone_do` 的 `unicode` 入口（`SendInput` Unicode，需 `confirm`）：**仅诊断用**，实测无法把字送进手机。
- 修 `.ps1` 编码：编辑后必须保留 UTF-8 BOM，否则 Windows PowerShell 按 ANSI 解析中文注释直接语法错。

## 0.2.0 — 2026-10-28

- 工具改为 MCP stdio server 挂载（`mcp__miphone__phone_*`），每个会话可用，无需等待 bundle 投影。
- 新增 `verify`：只比对目标区域，返回 `hit / tries / banner`，没变自动重试一次。
- 新增三档权限 `full / auto / ask`，改 `config.json` 即时生效。
- 截图固定写 `last.png` / `last.crop.png` 覆盖复用，启动时清理历史遗留与旧编译产物。
- 包名改为 `dsh-mi-phone-use`，新增 `install.ps1`（自动识别 profile、幂等、pnpm/npm 回退）。

## 0.1.0 — 2026-10-28

- 首个版本：窗口定位、后台截图、百分比坐标点击/滑动/长按、ASCII 逐键输入、中文剪贴板粘贴。
- 分块带容差差分，画面无变化时不返回图片。
- 三个工具 + 技能 `mi-phone`。
