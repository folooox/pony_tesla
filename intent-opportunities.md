# Pony App Intents 机会评估

## 现有清单

截至2026-10-23，Pony 声明0个 App Intent 动作；没有已接入的 Shortcuts、App Shortcuts、Spotlight、Siri、widget/control Intent，也没有 Apple Intelligence schema。对完整 ios/ 搜索 AppIntent、AppShortcut、AppShortcutsProvider、AppEntity、EntityQuery、@Assistant 和 import AppIntents 均未匹配；检查了唯一应用 target Pony、本地 PonyCore 包及测试源码。未声明不等于系统不能普通打开App；源码集成、可见性和实际执行是不同证据层级。

## 项目与范围

既有项目的新登录一次唤醒实现；不是首次导入。工作副本 login-wake-sync-20261023，基线0d1c2a5eeb1d663e7334086546bdf0c6cc39ecde；有未提交的原名称/提示补丁，以及本轮后台三运行文件、iOS两文件和测试改动。本报告依据当前源码快照，不称工作树干净；最终文件指纹随交付证据保存。

本次因新增业务动作、权限请求和服务入口而重新评估；未找到可复用的旧报告。已读 find-intent 全流程及模板、apple-integrations 的 App Intents 指南；指南示例不作为具体API可用版本的证据。本评估只阅读代码和SDK声明，不实现任何建议、不执行车辆动作、不改系统目标或权限。

| 目标 | 配置/源码 | 最低系统 | 工具链证据及边界 |
|---|---|---|---|
| Pony 主应用 | ios/Pony.xcodeproj/project.pbxproj 唯一 PBXNativeTarget，Debug/Release；原生账号和历史源码在 Sources 中，链接 PonyCore | iOS27.0，Swift6，默认MainActor | 实际只读构建机记录：Xcode27.0(27A266a)，macOS27.0(26A428)，iPhoneSimulator27.0.sdk；不是物理设备证据 |
| PonyCore / PonyCoreTests | ios/PonyCore/Package.swift 及 Sources/Tests | 包声明 iOS17/macOS14、tools6.0，不降低App下限 | 本轮核心64项实际合成测试通过；包没有 Intent/扩展 target |

已读 PonyApp.swift、NativeAccountViews.swift、NativeTeslaClient.swift、AppStore.swift、NativeHistoryStore.swift、ReadOnlyVehicleData.swift 以及 native-router.mjs/native-auth.mjs/core.mjs。ios/README 的旧演示记录不能替本轮真实流程背书。API证据摘录保存于开发工作区 saved-work/pony-login-wake-20261023/command-output/intent-sdk-evidence.txt，实际构建机记录3c8fbe51-3df5-4281-90c0-59d6a788445e；所有验证日期2026-10-23。

## 决策摘要

首批可立即实施：0项。保留两个按顺序待验证的机会：①仅打开车辆页；②账户绑定、持久选择后的只读车况查询。它们不是本轮新增范围。普通Intent和可选AI schema分别验证；不能把协议存在说成完整方案可交付。

新登录单次唤醒不推荐做成可复用Shortcut或自动化。它依赖新交互登录、前台窗口、用户官方同意和持久一次性领取，超时未知不允许重放。普通用户动作“查看车况”有价值，但不能复用会消费 freshSelectionIntent 的 select 分支、connect 或 loginSync，否则可能暗含唤醒。

## 候选1：打开车辆页 — 需验证，优先级1，S–M

业务页面已实现；系统入口未实现。实际链路：PonyApp.swift/PonyTabs 的 TabView(selection:) 与 @SceneStorage("pony.selected-tab") → 车辆Tab → 有会话时 NativeVehicleStatusView → NativeAccountState.reading/selectedVehicle。页面打开本身没有网络；无会话走演示VehicleView，不能冒充真实车况。

提议最小结果为前台打开车辆内容，无VIN参数，重复调用仅打开同页，不刷新、不重选、不发起登录或唤醒。未登录应清楚呈现真实账号连接说明，而不是声称打开某辆真车；这些路由规则是新增提议，当前没有 Intent→Tab handler。

身份策略与第二候选一致：不猜第一辆车，不公开VIN或位置，不索引私有车辆。未来若支持指定车辆，须以账户范围稳定标识查询，执行时重验权限；多车、移除、失效、跨账户都回前台选择。不能为打开页面自动登录，因为新登录会产生一次唤醒。

普通路径：调查 AppIntent 前台导航（证据E1–E3），不依赖AI。尚缺 IntentModes.foreground、结果构造、导航协议/SwiftUI处理器的实际声明和冷启动接线，故不是ready。S–M估计假设产品接受纯导航；成本来自路由、演示/真实隔离、冷启动和API核对，无频率数据。

系统入口分别判断：Shortcuts需声明及元数据验证；App Shortcut/Siri还需initializer/phrase/provider自己的证据；Spotlight可考虑不含私有内容的通用动作入口，不等于车辆索引；Apple Intelligence没有精确schema/member/实体依赖的SDK证据，不声明支持，不编造汽车专属schema或版本。

下一步：产品先确认“只打开、不读取、不唤醒”，再补精确SDK声明、最小路由与构建；分别记录元数据、Shortcuts/Spotlight可见性及签名实机执行。当前未实施或测试任何系统入口。

## 候选2：只读查询已选车辆状态 — 需验证，优先级2，M

手动只读业务已实现。链路：NativeVehicleSelectionSection → loadVehicles()/select(_:) → NativeAccountState.read(cached:) → NativeTeslaClient.snapshot/probe → authenticated/validSession → 原生后台认证会话族与当前车辆归属检查。probe 最少间隔15秒；snapshot也先向Fleet核对归属，不是离线缓存读取。probe可能保存服务器快照，读取可能旋转应用/Tesla令牌；“只读”不等于完全无副作用，但两条路径均不唤醒，不暗中转向loginSync。

selectedVIN、vehicles、reading目前只在内存；Keychain持久化会话而非目标选择。新登录待选择时select(_:)会消费freshSelectionIntent，不能直接给Intent复用。需新增账户绑定的持久目标选择、冷启动可用且脱离View的只读协调层，以及明确实时只读/缓存语义。未选、多车、账户切换、车辆移除统一回前台选择，不以任意VIN作为授权。

提议结果为少量电量/续航等字段和可信来源/时间。缓存不称当前实时，失败不偷偷切到演示/唤醒，缺字段未知。优先前台阅读；后台或语音结果另需产品确认最小敏感输出，不包含原始响应、VIN、坐标或轨迹。

访问边界：Keychain使用WhenUnlockedThisDeviceOnly，锁屏可能读不到；loadLocalSession保留不可读存储并提示解锁重试。hasLocalSession仅表示本机保存凭据，不代表服务仍授权；query与perform都须账户/车辆权限检查。过期、撤销、刷新未知不能后台偷偷登录。设备认证、App会话、车辆权限和执行确认分别处理，schema不替代授权。

普通路径需补参数、结果、认证策略具体成员、可能的实体/query API声明（E6）；不一定必须AppEntity，按最终无歧义方案决定。普通路径、后台生命周期和锁屏隐私均待验证，不列首批。可选AI schema没有已验证的精确成员和availability，不指定名称。Shortcuts/Siri有条件价值；Spotlight只考虑普通动作，不索引敏感车辆；Apple Intelligence支持未知。

M估计依赖持久选择、复用只读边界、权限、并发刷新/注销隔离和失败恢复。下一步先完成本轮原生真实读取、缓存无数据/过期/离线/401/429验收，再单独评估Intent；源码证明不等于真实服务或系统入口通过。

## API与可用性证据

来源为上述实际SDK的arm64-apple-ios-simulator.swiftinterface摘录，完整路径：/Applications/Xcode_27.0.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.0.sdk/System/Library/Frameworks/AppIntents.framework/Modules/AppIntents.swiftmodule/。摘录也列x86_64文件名，不因此声称两架构逐符号验证。SDK属性引用某类型不等于读到该类型及成员的声明。

| ID | 精确符号 | 摘录与最低iOS | 边界/下一步 |
|---|---|---|---|
| E1 | AppIntent protocol | SDK3096–3115，iOS16.0；含PerformResult、title、authenticationPolicy等要求 | 未覆盖所有被引用类型声明及执行语义 |
| E2 | AppIntent.openAppWhenRun | 协议处iOS16.0；iOS26.0 deprecated，3100–3105 | 新方案不依赖废弃属性；不证明导航已接 |
| E3 | AppIntent.supportedModes属性 | 3106–3107，anyAppleOS26.0 | 尚缺IntentModes及.foreground/.background成员声明 |
| E4 | AppShortcutsProvider / appShortcuts / updateAppShortcutParameters | 10727–10738，iOS16.0 | 不证明AppShortcut initializer、phrase token或可见性 |
| E5 | 拟需AppShortcut initializer及application-name插值 | 当前摘录未验证，版本不填 | 最终设计确定后读所选overload/builder/token自身声明及官方限制 |
| E6 | 拟需结果构造、参数/实体/query、认证策略成员、导航handler | 未验证，版本不填 | 逐符号核对，不为凑方案强加实体 |
| E7 | 可选AI schema精确域/成员/依赖实体 | 未验证，版本不填 | 指南只作线索；核查语义、参数/返回、动作组和availability后另决策 |

OpenURLIntent虽在摘录中有自身声明，项目目前只有认证回调URL，没有车辆deep link，不能把OpenURL说成现成车辆导航能力。未核对成员不靠记忆补版本；没有匹配schema不否定普通Intent价值。

## 已实现、规划与排除

| 任务 | 证据与状态 | 决策与重评条件 |
|---|---|---|
| 新登录一次唤醒并读车况 | connect→freshLoginSync/beginSelectedSync/runSelectedSync→client.loginSync→后台claimLoginSync/loginWake；最多4次5秒确认、目标流程60秒上限；只有新登录触发 | 业务候选已实现但实车未验，不推荐可重复Shortcut。独立唤醒产品需求须另立权限与安全范围 |
| 门锁、空调、充电等真控制 | supportedQuickControls始终空，后台commands:false；AppStore.execute走DemoVehicleService | 不推荐，以演示实现冒充真实能力会误导；真实服务/确认链验收后重评 |
| 真实行程/充电历史 | 客户端历史代码存在，但NativeHistoryStore需native_deployment_verified及features；当前后台均false、路由无history | 服务未开放，规划项，不列首批；后端和保留/归属规则验收后重评 |
| 演示备注/导出/清理、布局 | AppStore/演示服务数据；布局UserDefaults | 非真实账户任务或价值低，本轮不集成不索引 |
| 退出/删除账号 | logout本机清理并尽力远端撤销；deleteAccount明确不可用 | 退出不列首批，不能把它称撤销Tesla/删除数据；删除业务未实现 |
| 私有VIN/位置/轨迹搜索索引 | 无实体/query/索引实现 | 本轮不建议建立敏感资产；明确需求、账户隔离与清理方案齐备再议 |

## 交接

现有Intents仍为0，首批推荐0项；待验证顺序为纯导航→账户绑定且持久选择的只读车况。本轮不实现任何Intent，不把登录单次唤醒变成自动化。实施下一项需产品独立决定；源码、SDK声明、编译、系统入口可见性、模拟器运行、签名设备运行和实车结果分别记录，互不替代。
