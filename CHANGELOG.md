# CHANGELOG

## 0.3.3 — 2026-10-29

- **修正 0.3.2 的误报**：之前只要找到窗口就报唤醒成功，实测把屏幕外（`-21333,-21333`）、最小化、内容纯白的空壳窗口当成了可用画面。
- `phone_wake` 改为**纯后台**恢复：只用 `ShowWindow(SW_SHOWNOACTIVATE)` + `SetWindowPos(SWP_NOACTIVATE)`，不点任务栏/托盘、不发 `SendInput`、不动鼠标、不抢焦点。
- 新增空白检测：采样色数 ≤3 且亮度标准差 <6 判定为空白，此时返回 `state:"screen-not-projected"` + `deviceState:"not-connected"`，并说明"多半不在同一局域网，此时不需要指纹解锁"；连窗口都没有则返回 `phone-not-found`，用于判断设备不在身边。
- `Resolve-Target` / `restore` 也改走后台恢复：被收起或推到屏幕外的窗口能找回，不再报 `content child not found`。
- `phone_see` 在画面空白时返回 `{"blank":true,"state":"screen-not-projected"}` 且不回图片，省 token。
- 同步 README / DEVLOG / skill 文档的 `state` 语义表。

## 0.3.2 — 2026-10-29

- 新增 `phone_wake`：后台尝试启动 XiaomiPcManager、恢复最小化窗口，并等待手机画面子窗口。
- `phone_wake` 成功后固定返回 `unlockRequired:true`，明确要求主人手动完成手机指纹解锁；插件不点击锁屏、授权或配对按钮。
- CLI 新增 `node cli.mjs wake`；同步修正顶层 `clip:"@restore"` 的实际实现，使其与 batch 行为一致。
- 清理即将提交内容中的本机路径和个人环境信息；不推送远程仓库。

## 0.3.1 — 2026-10-29

- 清理死代码：删除从未被调用的 `Send-UnicodeInput`（含 C# `SendInput`/`INPUT` 声明）、`Invoke-Paste`/`Send-Combo`（含全局 Ctrl 注入）、`Get-BitmapStream`、`restoreclip` 动作，以及 `Invoke-PasteAt` 里已被否掉的“逐个试点击菜单项”逻辑。
- 删除一次性实验脚本：`scripts/probe-text.ps1`、`scripts/mi-phone-text-probe.ps1`、`scripts/ocr-probe.ps1`（结论见 DEVLOG D7/D11b）。
- 修复 `openmenu` 动作没有把待粘贴文字传进去的问题。
- 中文输入统一为：`openmenu` 出菜单图 → 看图算坐标 → 单次 `tap` → `inserted` 校验 → `clip:"@restore"`。

## 0.3.0 — 2026-10-28 （unicode 诊断入口已在 0.3.1 移除）

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
