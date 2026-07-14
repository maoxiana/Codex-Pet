# Reborn 每周额度伴随进程设计

日期：2026-07-13

## 背景与目标

Codex 自定义宠物 v2 包只包含 `pet.json` 与精灵图，不提供脚本、数据绑定或自定义 UI 插槽。因此，不能仅靠修改 Reborn 宠物文件显示真实、实时的每周额度。

本方案新增一个轻量原生 macOS 伴随进程，在不修改 `ChatGPT.app` 的前提下：

- 读取 Codex 的真实 rate-limit 数据；
- 在 Reborn 上方显示精简额度胶囊；
- 悬停或点击时展开进度与重置时间；
- Reborn 移动、隐藏或重新出现时同步调整；
- Codex 更新、伴随进程异常或额度接口暂不可用时不影响 Codex 本体。

## 已确认的交互

采用方案 B：精简常驻，按需展开。

### 收起状态

- 位于 Reborn 上方，箭头指向角色；
- 文案为“本周剩余 72%”；
- 只显示真实百分比，不显示估算消息数；
- 黑色半透明气泡、橙色百分比，延续 Reborn 的黑橙配色。

### 展开状态

- 鼠标悬停或点击气泡时展开；
- 显示“每周额度”、剩余百分比、进度条与本地化重置时间；
- 点击可以固定展开，再次点击或点击外部后收起；
- 展开时保持气泡底部锚点不变，避免相对 Reborn 跳动。

### 可访问性与动效

- 为百分比、进度条与重置时间提供 VoiceOver 标签；
- 系统开启“减少动态效果”时禁用尺寸过渡；
- 正常模式下使用约 140ms 的轻微展开过渡；
- 气泡不成为 key window，避免夺走 Codex 的输入焦点；本版以鼠标悬停和点击交互为主；
- 百分比变化通过可访问性 value 暴露，但不承诺完整键盘操作。若后续要增加键盘交互，必须单独设计焦点转移与恢复，不能让非激活面板隐式抢焦点。

## 架构

源码放在现有最新 Reborn 工作目录内，避免新增多个顶层宠物目录：

```text
reborn-transformation-gun-run/
  companion/
    Package.swift
    Sources/RebornQuotaCompanion/
      AppDelegate.swift
      CodexRateLimitClient.swift
      WeeklyQuotaModel.swift
      PetWindowLocator.swift
      QuotaPanelController.swift
      QuotaBubbleView.swift
    Tests/RebornQuotaCompanionTests/
    scripts/
      build_app.sh
      install_app.sh
      uninstall_app.sh
    dist/RebornQuota.app
```

使用 Swift、AppKit 与 SwiftUI，不引入第三方运行时。最终产物是 `LSUIElement` 类型的 `.app`：默认不显示 Dock 图标和主窗口，只显示额度浮层。

### 1. CodexRateLimitClient

伴随进程启动自己的 Codex App Server 子进程，通过标准输入/输出使用 JSON-RPC 协议。它使用 Codex 已有登录态，但不直接读取、复制或记录任何访问令牌。

数据流程：

1. 从固定候选路径定位 Codex CLI；
2. 启动 `codex app-server --stdio`；
3. 发送带递增 request id 的 `initialize` 请求，参数包含 `clientInfo.name`、`clientInfo.version` 与 `capabilities.experimentalApi: true`；
4. 收到初始化响应后发送无参数的 `initialized` 通知；
5. 调用 `account/rateLimits/read`，请求显式使用 `params: null`；
6. 收到 `account/rateLimits/updated` 时把它当作“数据已变化”的失效信号，立即重新调用完整的 `account/rateLimits/read`，不在本地猜测合并稀疏嵌套字段；
7. 每 60 秒主动刷新一次，作为通知丢失时的兜底；
8. 子进程断开后按 1、2、4、8、30 秒退避重连。

LaunchAgent 没有交互式 shell 的 `PATH`。CLI 按以下顺序发现：

1. 安装时写入配置的绝对路径；
2. `/Applications/ChatGPT.app/Contents/Resources/codex`；
3. `~/Applications/ChatGPT.app/Contents/Resources/codex`；
4. 仅开发运行时使用当前进程环境中的 `CODEX_CLI_PATH` 或 `PATH`。

候选文件必须可执行，且 `codex --version` 在 2 秒内成功。找不到或版本不兼容时进入 `unavailable`，不循环启动失败进程。

传输采用 Codex 生成 schema 对应的逐行 JSON 消息。读取端允许未知字段，并按 request id 关联并发响应；未知通知被忽略。标准输出只用于协议帧，标准错误持续异步排空到大小受限的诊断缓冲。初始化、读取和关闭分别设置 5 秒、8 秒和 2 秒超时；超时或 malformed frame 会终止并回收子进程后重连。退出时关闭 stdin、等待子进程，超时后再终止，保证没有孤儿 app-server。

完整读取使用 single-flight actor 状态机：同一时间最多一个 `account/rateLimits/read` 在途。读取期间收到通知或定时刷新，只把 `dirty` 标记设为 true；当前读取结束后合并成一次 follow-up read。每次 app-server 重连递增 `connectionEpoch`，只有当前 epoch 且未被 `dirty` 标记淘汰的响应可以发布到 UI，旧连接或旧 generation 的响应直接丢弃。`lastUpdatedAt` 只在发布一个当前 epoch、非过期的完整 snapshot 时更新；重复返回过期 `resetsAt` 不能延长 30 秒宽限期。

过期重置时间的主动刷新按 snapshot fingerprint（`limitId`、窗口位置、`usedPercent`、`resetsAt`）去重：同一 fingerprint 最多触发一次立即刷新。若刷新后 fingerprint 未变且仍过期，进入 `refreshing`/宽限期，不再立即循环读取，只等待通知或 60 秒定时刷新。

读取 `rateLimitsByLimitId["codex"]`，不存在时回退到兼容字段 `rateLimits`。在选定 snapshot 的 `primary`、`secondary` 中查找 `windowDurationMins == 10080` 的窗口：只有一个时选择它；两个都是周窗口时优先 `secondary`，因为兼容 payload 通常把较长窗口放在那里，同时记录诊断 warning；两个都不是则视为“无每周额度”。`windowDurationMins == null` 不能推断为周窗口。

App Server 提供 `usedPercent`，UI 使用 `clamp(100 - usedPercent, 0...100)` 得到剩余百分比。`resetsAt` 可为空；有值时按 Unix 秒转换为用户当前时区，没有值时显示“重置时间暂不可用”。若时间已过去，立即触发一次完整刷新；刷新后仍过期则保留百分比但标记“正在更新”，不显示过期时间。

### 2. WeeklyQuotaModel

模型暴露以下状态：

- `loading`：正在建立连接；
- `available(data, lastUpdatedAt)`：有明确且当前有效的每周窗口；
- `refreshing(lastKnownData?, refreshingSince)`：正在重新确认数据；`lastKnownData` 可为空，30 秒宽限期始终从 `refreshingSince` 计算，而不是依赖上一次新鲜时间；
- `noWeeklyWindow`：已成功读取，但没有明确的 10080 分钟窗口；
- `unavailable(reason)`：未登录、协议错误、子进程不可用或持续断线。

渲染规则：`loading` 显示“正在读取额度”；`available` 显示百分比；`refreshing` 有 `lastKnownData` 时在 30 秒宽限期内显示最后值并加“正在更新”，没有历史新鲜值时只显示“正在更新额度”；超过宽限期进入 `unavailable(.staleSnapshot)`；`noWeeklyWindow` 显示“暂无每周额度”；缺少 `resetsAt` 时展开态显示“重置时间暂不可用”。日志只记录状态与错误类别，不记录账户信息、额度负载或令牌。

### 3. PetWindowLocator

伴随进程不修改 ChatGPT 的渲染代码，而是定位 ChatGPT 所拥有的宠物浮窗。窗口定位必须先完成 feasibility spike；只有当前 Codex 版本在 Reborn 显示、隐藏、拖动及通知面板打开时都能稳定区分宠物窗口，才进入正式实现和安装。

支持的宿主 bundle id 以 spike 实测为准，并写成小范围 allowlist；进程必须来自该 bundle id 的当前运行实例。定位流程：

- 首选 `CGWindowListCopyWindowInfo` 读取宿主进程的可见窗口边界；
- 记录并验证稳定 discriminator：owner PID、layer、bounds 范围、alpha、z-order、与宿主主窗口的关系，以及宠物显隐前后的差分；
- 必须能排除通知、快捷窗口、菜单和其他小浮窗；若没有稳定 discriminator，该会话永久隐藏气泡并报告诊断，不使用“最小窗口”等脆弱猜测；
- 只有 spike 证明宠物窗口出现在 AX 树中时，才将 Accessibility API 作为移动/大小事件源；否则不宣传 AX fallback；
- CGWindow 坐标转换为 AppKit 坐标时使用对应 `NSScreen` 的 frame 与 Y 轴翻转，并覆盖负坐标、多屏排列和不同缩放；
- 无 AX 事件时静止状态以 10Hz 采样；发现边界变化后临时提升到 60Hz，连续 300ms 不再变化后回到 10Hz；首次移动检测最迟 100ms，移动期间目标跟随延迟不超过 34ms；
- 有稳定 AX moved/resized 通知时使用事件驱动更新，并保留 1Hz 校验采样；
- 宠物隐藏、Codex 退出或候选窗口不明确时，隐藏额度面板而不是猜测位置；
- 多显示器情况下将气泡限制在宠物所在屏幕的 `visibleFrame` 内；切换 Space、最小化或宠物不再出现在 `.optionOnScreenOnly` 列表时隐藏；
- 目标性能为静止时平均 CPU 小于 1%，拖动时平均 CPU 小于 5%（Apple Silicon 当前机器实测）。

本方案不承诺像素级判断宠物是否被另一个应用的窗口遮住。只要宠物窗口仍被系统列为当前 Space 的 on-screen window，额度气泡就与宠物一起保持浮动；这符合桌面宠物跨应用可见的语义。spike 必须测得宠物的实际 window layer，额度 panel 使用 `petLayer + 1`，并限制在 `.floating` 到 `screenSaver - 1` 的安全范围内。panel 的 `collectionBehavior` 固定为 `.canJoinAllSpaces`、`.fullScreenAuxiliary`、`.ignoresCycle`；但仍由宠物是否出现在当前 on-screen 列表决定显隐。必须在普通 Space、切换 Space 和全屏 Space 中验证气泡不会单独遗留。

实现阶段必须用当前 Codex 版本实测窗口识别条件，不能仅依赖窗口标题，因为标题可能为空或随版本变化。

### 4. QuotaPanelController 与 QuotaBubbleView

使用无边框、透明、非激活型 `NSPanel`：

- 层级高于普通窗口，但不抢占 Codex 键盘焦点；
- 收起尺寸约为 `164 × 32pt`；
- 展开尺寸约为 `200 × 82pt`；
- 默认在 Reborn 窗口顶部中央上方保留 8pt 间距；
- panel `canBecomeKey == false`，不抢占 Codex 键盘焦点；可见气泡区域接收鼠标，窗口尺寸严格收缩到气泡 bounds，避免依赖大面积透明 click-through；
- 点击固定展开时安装进程内和全局 mouse-down monitor；外部点击只负责收起，monitor 在收起、隐藏和退出时立即移除；若全局 monitor 需要额外权限而用户未授予，则退化为鼠标离开后延迟收起；
- 宠物拖动期间跟随，展开状态不会改变锚点。

几何选择始终使用“展开态最大包络尺寸”，而不是当前收起尺寸：优先判断展开态能否完整放在 Reborn 上方并保留 8pt；不能时再判断下方并翻转箭头；若上下都不能容纳展开态，则即使收起胶囊能够放下也隐藏。气泡显示后锁定 placement side，直到宠物跨屏、屏幕布局变化或气泡重新隐藏/显示才重新计算。水平方向始终在 `visibleFrame` 内平移限位。展开或收起只改变远离宠物的一侧，指向宠物的边与箭头锚点保持不变，因此交互过程不会从上方跳到下方。

## 生命周期与安装

构建脚本生成 `companion/dist/RebornQuota.app` 并进行 ad-hoc 签名。重复构建的签名身份或 bundle 发生变化可能使 Accessibility 授权失效，因此安装后版本使用稳定 bundle id，升级时复用同一安装路径并在授权失效时给出一次说明。

安装脚本在获得用户许可后：

- 复制到 `~/Applications/RebornQuota.app`；
- 写入 `~/Library/LaunchAgents/com.maoxian.reborn-quota.plist`，配置 `RunAtLoad: true`、`KeepAlive` 仅在异常退出时重启、`ThrottleInterval: 30`，登录后自动启动；
- 立即启动一次伴随进程。

应用使用单实例锁；第二个实例检测到已运行后直接退出。ChatGPT 未运行时不启动 app-server，只以低频监听宿主启动；宿主退出后终止并回收 app-server 子进程并隐藏 UI。安装使用幂等的 `launchctl bootout`、复制、`launchctl bootstrap` 流程；卸载先 `bootout`，再移除自身 App 与 LaunchAgent，不触碰 Reborn 宠物、Codex 配置或 `ChatGPT.app`。连续崩溃由 launchd 的 30 秒节流限制，应用本身也记录本次启动失败次数，避免忙循环。

若窗口 spike 证明必须使用 Accessibility：首次仅展示一次用途说明，然后调用系统授权提示；拒绝状态持久化，不循环弹窗，并提供打开“系统设置 → 隐私与安全性 → 辅助功能”的入口。应用每 30 秒低频检查权限是否后来改变。若实现采用全局事件监控并触发 Input Monitoring 权限，则必须走同一套说明、拒绝与降级路径；优先避免引入第二种权限。

## 错误与降级

- App Server 不可用：显示“额度暂不可用”，后台退避重连；
- 没有 10080 分钟窗口：显示“暂无每周额度”，不拿其他窗口替代；
- Reborn 窗口未找到：隐藏气泡，继续低频检测；
- 辅助功能或输入监控权限未授予：优先使用无需权限的窗口信息与 hover 自动收起；仍无法定位时显示一次系统说明，不循环弹窗；
- 多个候选宠物窗口：只在置信度足够时显示，否则隐藏；
- 伴随进程崩溃：不影响 Codex，LaunchAgent 可以重新启动它。

## 测试与验收

### 单元测试

- 正确识别 `primary`、`secondary` 中的 `10080` 分钟窗口及双命中优先级；
- 不把 300 分钟、1440 分钟或月度窗口标为每周；
- 覆盖 `windowDurationMins == null`、`resetsAt == null`、重置时间已过和没有周窗口；
- 覆盖首次 snapshot 即过期、无历史新鲜值、一次去重 refetch 后仍过期，以及 30 秒后进入 stale unavailable；
- `usedPercent` 正确转换并限制为 0–100%；
- `resetsAt` 正确转换到本地时区；
- 稀疏更新只触发完整 refetch，覆盖更新先于首个 snapshot、重复更新与 refresh/update race；
- 断线宽限期和退避状态机正确；
- 气泡位置在单屏、多屏和屏幕边缘正确限位。
- 顶部空间不足时正确翻到宠物下方并翻转箭头，上下都不足时隐藏；
- 使用展开态包络预选并锁定上下方向，收起与展开切换时不得换边；

### 集成测试

- 用假 App Server 验证初始化、读取、更新通知、请求超时、malformed frame、out-of-order 响应、auth 变化、错误、重连和子进程回收；
- 用假窗口列表验证 Reborn 候选筛选、坐标转换、Space/occlusion 和隐藏逻辑；
- 对进程 transport、JSON 编解码、时钟、scheduler、CLI discovery、窗口 provider、screen geometry、权限状态和 mouse monitor 使用显式 protocol 注入，确保测试不依赖真实 Codex；
- 验证点击固定、外部点击收起、monitor 清理和 Codex 焦点不被夺取；
- 构建后的 `.app` 可以在无 Dock 图标条件下启动并退出。

### 窗口定位 feasibility spike 验收

- 在 Reborn 显示、隐藏、拖动、改变大小、展开通知面板、切换 Space、多显示器移动时采集窗口元数据；
- 形成不依赖窗口标题的稳定 discriminator，并用自动 fixture 回放；
- 在当前机器上移动跟随延迟满足：启动移动检测不超过 100ms，移动期间不超过 34ms；
- 静止 CPU 小于 1%，拖动 CPU 小于 5%；
- 验证测得的 pet layer、`petLayer + 1` panel 层级、普通/全屏 Space 行为，以及其他应用覆盖宠物时气泡仍与宠物共同浮动；
- 若任一项不能满足，停止安装并回到设计阶段，不修改 `ChatGPT.app` 作为绕过方案。

### 手工验收

- Codex 中唤醒 Reborn 后，气泡出现在其上方；
- 拖动 Reborn 时平滑跟随；
- 收起状态显示真实每周剩余比例；
- 悬停和点击展开，显示进度条及重置时间；
- 隐藏 Reborn 后气泡随之消失；
- 关闭、重新打开 Codex 后能够恢复；
- 网络断开、未登录或额度接口异常时不显示错误数据；
- Codex 与 Reborn 的现有动画、点击、通知面板和输入焦点不受影响。

## 不在本次范围内

- 修改或重新签名 `ChatGPT.app`；
- 在宠物精灵图中绘制静态额度文字；
- 显示信用余额、5 小时额度、每日/月度额度或多个模型的明细；
- 购买额度、使用 reset credit 或修改账户设置；
- 将伴随进程发布到 App Store。
