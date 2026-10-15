# Pony 原生 iOS 工程

以 **Xcode 27 / iOS 27 SDK** 为目标，最低运行版本 iOS 27.0。纯 SwiftUI，使用系统字体、SF Symbols、MapKit、Swift Charts 和原生 Liquid Glass 控件。

2026-10-15：已完成本轮界面和模拟交互逻辑重构。Linux 上通过 20 项核心逻辑测试、15 项状态流程检查，以及 Swift 语法、工程引用和 Scheme XML 检查。**尚未使用 iOS SDK 构建，也未在模拟器或实机运行；原生外观待 Mac 验证。** 旧 `screenshots/` 属于已放弃的网页视觉方向，不代表本工程效果。

## 本轮实现

- **车辆**：车况、最多 4 个首页快捷控制的增删排序与本地保存、完整控制列表、空调温度与模式草稿、定位地图和地点搜索。操作收到模拟服务确认后才更新状态，并记录结果。
- **行程**：最近 168 小时及按日期筛选、汇总、地图轨迹、速度/功率/电量曲线、共用时间轴回放、标签备注和 CSV 导出。缺失数据展示为空值，地图和曲线保留缺口，不自动连线。
- **充电**：电量、功率、充入电量、充电历史、上限草稿与确认、模拟开始/暂停。动画跟随状态和系统减少动态效果设置，没有费用模块。
- **我的**：首页控制编辑、操作记录、模拟历史清理与导出、账号状态和 7 种测试场景。

系统 TabView、NavigationStack、List、Form、sheet、toolbar 和确认框负责导航及交互。快捷控制使用 GlassEffectContainer 和 glass 按钮，主要充电操作使用 glassProminent；内容区保持系统可读表面。支持系统深浅色、Dynamic Type 和语义颜色；大字号指标列改为纵向。

所有车况、行程和充电记录均为合成数据，演示操作不控制真实车辆。车辆图形使用 SF Symbol 占位。账号授权、真实控车、远程采集尚未接入；后端已提供历史存储、查询及到期清理接口，本原生演示尚未对接；座椅等扩展空调控制、诊断子项、充电预约和发送导航仍为待实现入口。后端已有的单车主连接测试工具尚未成为原生客户端的用户会话服务。

完整的首次安装、脚本构建、模拟器运行与实机签名流程见 [Mac 编译指南](../docs/mac-build.zh-CN.md)（[English](../docs/mac-build.en.md)）。

## 在 Mac 上打开

1. 安装带 iOS 27 SDK 和相应模拟器的 Xcode 27。
2. 打开 `ios/Pony.xcodeproj`，选择 **Pony** scheme 和 iOS 27 模拟器。
3. 直接 Run；这是完整的 SwiftUI App 工程，不需要另建 Cocoa Touch 模板。PonyCore 为仓库内的本地包，无远程包依赖。
4. 首次以正常演示场景启动，在“我的 → 模拟器测试”切换场景。按 [模拟器测试清单](SIMULATOR-CHECKLIST.md) 验证。

在仓库根目录或源码包解压根目录运行：

```sh
xcodebuild -project ios/Pony.xcodeproj -scheme Pony \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

当前环境无法验证该命令的结果，首次在 Mac 上应先处理 SDK 类型检查或运行问题，再进行视觉验收。实机运行需设置自己的签名团队；应用图标、发布资料及发行归档尚未完成。

在 scheme 的 Run → Arguments 中可以配置两个参数：`-scenario` 和以下值之一：

| 值 | 场景 |
| --- | --- |
| normal | 正常数据与可操作车辆 |
| empty | 无行程、无充电历史 |
| asleep | 车辆休眠，禁止操作 |
| offline | 离线缓存，禁止操作 |
| error | 服务错误和重试入口 |
| expired | 授权失效和重试入口 |
| missingData | 轨迹/曲线缺口、缺失字段及部分控制不可用 |

重置或切换场景会重新生成模拟记录。退出应用后模拟车况、备注和历史不持久化；快捷控制布局通过 UserDefaults 保存。MapKit 地图和地点搜索需要网络，搜索文字会提交给地图服务。工程不包含 Tesla 凭据。

## 代码结构

```text
Pony/             SwiftUI 页面、AppStore 与应用入口
PonyCore/         Foundation 数据模型、保留规则、CSV、VehicleService 与模拟实现
  Tests/          Swift Testing 核心测试
Checks/          AppStore 流程检查及工程结构检查
Pony.xcodeproj/  App target、共享 Pony scheme、本地包引用
check-logic.sh    无需 iOS SDK 的逻辑与结构检查
```

AppStore 统一处理加载、错误、数据时效、操作互斥及旧请求结果失效；界面不直接调用 Tesla API。VehicleService 将服务接口与界面分开，当前实现 DemoVehicleService 使用 actor 管理内存数据。后续真实服务实现仍需要身份认证、数据协议和命令能力适配，不能只替换服务器地址。

## 逻辑检查

需要 Swift 6.2 或更高版本，在仓库根目录执行：

```sh
bash ios/check-logic.sh
```

脚本运行核心测试、编译并执行 AppStore 检查、解析 SwiftUI 源码语法和工程结构。SwiftUI 语法解析不验证 iOS API 类型、链接、布局或系统材质。当前没有原生 XCTest/UI Test target，不能用该脚本代替模拟器测试。

具体环境、覆盖范围和待验证项见 [验证记录](VALIDATION.md)。

## Apple 官方依据

- [WWDC26：What’s new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
