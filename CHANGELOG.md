# CHANGELOG

## 0.3.9 — 2026-10-29

- **移除动画判据**：连接页/失败页的区分不再依赖「画面是否在动」，全部改由 OCR 文字判定。相关代码（`Test-SurfaceAnimating`、文字包围盒几何判据）已彻底删除。
- **新增 OCR 语言包自检**：`phone_wake` 返回新增 `ocrAvailable` 与 `ocrHint`。未装简体中文 OCR 时 `ocrAvailable:false`，`ocrHint` 给出安装指引，并明确告知「自动唤起功能会受限」。
- OCR 不可用时无法区分连接页/失败页/解锁页，此时按失败处理并提示排查，不会误报成功。

## 0.3.8 — 2026-10-29

- **改用 Windows 内置 OCR（zh-Hans）判断页面状态**，这是最可靠的判据。
  - 之前判定「OCR 无效」是错的：当时测的是 16px 小字且画面模糊。实际投屏里「正在连接...」「手机解锁」「加载失败」字体够大，Windows OCR 识别准确。
  - 实测四类页面：连接页→`正在连接．．．`、解锁页→`手机解锁手机已锁屏，请在手机端解锁屏幕`、失败页→`加载失败点击小米社区反馈`、真实画面→噪声（不命中关键词）。
  - 因此真实画面（含正在播放的视频）**永远不会**被误判成连接页或失败页。
- 判据优先级调整为：**OCR 文字 > 动画 > 颜色**。OCR 不可用时才回退到几何判据。
- OCR 调用放在截图保存之后（此前放在保存之前，读不到文件）。

## 0.3.7 — 2026-10-29

- **修正连接页/失败页判据**：此前用「蓝字包围盒」区分，但连接页的彩色圆点（紫/粉/绿）也是蓝色系，会误判成失败页。改用主人实测的可靠依据——**连接页的圆点在动、失败页完全静止**。
  - 占位页（几乎全白或整屏过暗）先判定；
  - 占位页里若是「手机解锁」大插图 → `awaiting-unlock`；
  - 否则看画面是否在动：在动 → `connecting`，静止 → `connect-failed`。
- **修正 MCP 层硬编码**：`phone_wake` 曾一律返回 `unlockRequired: true` 且丢弃 `state`/`unlockState`；现在按真实状态透出，失败时完整返回 `state`/`deviceState`/`error`/`userActionRequired`。
- 实测：连接页连续采样哈希每次变化（animating=true）→ `connecting`；失败页哈希完全一致 → `connect-failed`。

## 0.3.6 — 2026-10-29

- **去掉设备 ID 依赖**：实测 Handoff 只需 `--CastBusinessType=1` 即可，管家会自己找到已连接的设备。不再需要任何配置文件，安装即用。
- 删除 `config.local.json` 及其 gitignore 条目。
- `package.json` 的 `files` 补上 `install.ps1`（此前打包会漏）。
- 修正 `install.ps1` 结束提示：工具数量由三个改为四个（含 `phone_wake`）。
- README 安装前提同步更新，明确「不需要填设备 ID 或任何配置」。

## 0.3.5 — 2026-10-29

- **实现全自动唤起**（主人实测流程）：
  1. 以管家为父进程启动 `MiSmartShareHandoff.exe`（妙享桌面）——直接用 PowerShell 启动会变孤儿进程，窗口虽在但内容渲染不出来；
  2. 纯后台恢复启动器窗口（它常是最小化、坐标 `-21333,-21333`、客户区 0×0）；
  3. 先投递 `WM_ACTIVATE` 再发鼠标消息点击——**实测只发 WM_LBUTTONDOWN/UP 完全无效**，补 WM_ACTIVATE 才能拉起跨屏协作；
  4. 妙享桌面自己拉起「跨屏协作」并自行关闭，最终只剩一个窗口。
- **禁止同时启动 MiScreenShare.exe**：那样会多弹一个独立窗口、破坏握手，表现为加载页长时间不结束、最后报「无法连接」。
- 占位页判据补充「整屏过暗」：窗口刚创建未渲染时是黑屏（实测 dominant=0.74、74% 为黑），此前会被误判成真实画面。
- 唤醒改为连续采样到状态稳定，避免把过渡帧当成最终结果。
- 设备信息从 `config.local.json` 读取（已 gitignore），不写进仓库。

## 0.3.4 — 2026-10-29

- **修正窗口识别**：主人点任务栏「妙享桌面-<设备名>」后，窗口先以一个自绘窗口类出现（过渡态、无子窗口），随后演变成「跨屏协作」`kMiScreenShareMainWindow`（带 `kMiChildSharedWindow`）。两个标题都识别，优先取正式窗口。
- **状态判据重做**：只识别三个已知占位页，其余页面（含解锁后停在任何 App）一律视为真实内容。
  - 加载页 / 加载失败页 / 手机解锁页 → 通过「主色占比 ≥ 0.94」先判为占位页；
  - 解锁页再按「蓝色插图包围盒 ≥ 30% 宽、15% 高 + 存在黑色标题」区分；
  - 有蓝字但无大插图 → 加载失败页；
  - 其余 → 真实画面。
- 修掉三个 bug：`errorPage` 引用未定义变量恒假；`Get-SurfaceStats` 漏算 `unlockPage`；蓝色包围盒在 `Get-SurfaceStats` 中从不更新。
- `Invoke-Capture` 与 `Get-SurfaceStats` 采样密度统一为 96×96，避免细小文字漏采。
- 新增 `scripts/capture-cast-flow.ps1`：一次性取证工具，记录进程/窗口/管道变化，用于分析管家如何发起投屏。

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
