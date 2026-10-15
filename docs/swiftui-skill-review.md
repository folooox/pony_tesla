# SwiftUI Agent Skill 研究与项目对照

检查日期：2026-10-14。

来源：[twostraws/SwiftUI-Agent-Skill](https://github.com/twostraws/SwiftUI-Agent-Skill)。本次读取的提交为 `f9800713b24580bc444931949aad4519128605e8`，提交日期 2026-10-07；技能元数据版本为 `2.0.0`，名称 `swiftui-pro`，作者 Paul Hudson。

## 结论

适合作为 Pony 原生 iOS 开发与代码审查的参考。其重点是现代 SwiftUI API、系统交互、布局、状态管理、性能和辅助功能。它提供开发规则，不包含可直接套用的 Tesla UI 或原生截图生成环境。

本次已按其设计、辅助功能、导航、布局及工程卫生建议做局部对照。没有全局安装技能，没有执行仓库提供的安装命令，也没有依据审查建议重构当前业务代码。

## 对当前项目最有价值的规则

1. **原生控件与导航**：使用系统 TabView、toolbar、sheet；避免手工模拟系统栏和安全区。
2. **Liquid Glass 交互来源**：确认弹窗应附着于触发控件；属于系统溢出菜单的操作例外，需要在菜单之外承载弹窗。
3. **工具栏优先级**：通用附加操作参与系统 ToolbarOverflowMenu，只有不可缺少的操作才固定在 topBarPinnedTrailing。
4. **字体和可读性**：使用语义字号与 Dynamic Type；谨慎使用 caption 和分散的字重覆盖。字体之外，还要检查放大后的重排、按钮命中面积和可读性。
5. **窗口适配**：不假设一个固定 iPhone 屏幕尺寸；保留各窗口尺寸下的功能入口和导航状态。
6. **数据流**：共享模型使用 Observation；区分业务状态与单窗口 UI 状态；避免状态重复维护。
7. **代码组织与验证**：业务逻辑可独立测试；复杂页面拆成独立 View；实际 UI 通过 Xcode 预览或设备运行检查。

## 版本建议的核对

技能主文件包含 Xcode 27.1 / Swift 6.4 建议，部分引用文档已涉及 27.2。Apple 的[当前工具链表](https://developer.apple.com/xcode/system-requirements)区分 Xcode 27、27.1 RC 和 27.2 beta。采用某一条规则前，仍要检查项目使用的 SDK 和 API 可用性，不能把整个仓库里的新 API 一起套入。

`SWIFT_VERSION = 6.0` 指 Swift 6 语言模式，不能据此推断编译器不是 Swift 6.4，也不应直接把该设置改成 `6.4`。参照同一官方表中 Compiler 与 Language mode 的区分。

## 当前工作区的局部发现

以下为本次读取时的工作区快照。工程尚未通过本次 Xcode 构建验证；这些是代码检查发现，不是模拟器测得的外观问题。

### `ios/Pony.xcodeproj/project.pbxproj:14`

**高优先级：工程文件引用应与实际源文件一致。**

工程仍引用不存在的 `PreviewModel.swift`；实际的 `AppStore.swift` 没有列入该工程。部分源文件已 `import PonyCore`，但工程尚未声明该本地 Package 的产品依赖。先完成这次迁移，才能进行原生构建验收。

```text
当前：PreviewModel.swift 引用；未列入 AppStore.swift；未配置 PonyCore 产品依赖
建议：引用 AppStore.swift；将本地 PonyCore 添加到项目和应用 Target 依赖
```

### `ios/Pony/ChargingView.swift:4`、`ios/Pony/ProfileView.swift:4`、`ios/Pony/TripViews.swift:22`

**高优先级：视图与共享模型应使用一致的数据来源。**

这些文件仍依赖已不存在的 `PreviewModel` / `PreviewTrip`；应用入口、车辆页和地图组件已经使用 `AppStore` / `PonyCore`。迁移需要同时更新属性、数据绑定与空数据处理，不能仅替换类型名称。

```swift
// 当前旧模型依赖
@Environment(PreviewModel.self) private var model

// 迁移方向；页面内读写也需同步重构
@Environment(AppStore.self) private var store
```

### `ios/Pony/VehicleView.swift:43–54`

**中优先级：通用附加操作应使用系统溢出菜单；确认弹窗应有明确触发来源。**

当前把整个省略号 Menu 固定在 `.topBarPinnedTrailing`。技能建议改为系统 `ToolbarOverflowMenu`，让系统决定收纳方式，而不是把通用菜单当作不可隐藏的核心操作。

```swift
// 当前
ToolbarItem(placement: .topBarPinnedTrailing) {
    Menu("车辆操作", systemImage: "ellipsis") {
        Button("编辑快捷控制") { editing = true }
        // 其他附加操作
    }
}

// 建议方向，按 Xcode 27 SDK 验证
ToolbarOverflowMenu {
    Button("编辑快捷控制", systemImage: "slider.horizontal.3") { editing = true }
    // 其他附加操作
}
```

快捷控制的确认弹窗现在附在车辆页面外层。提取独立的快捷控制按钮 View，并在该按钮上声明确认弹窗，可以明确玻璃过渡的来源；全局错误反馈仍由页面或根节点管理。

```swift
// 当前结构
ScrollView { /* 包含多个按钮 */ }
    .confirmationDialog(/* 共用的确认状态 */)

// 建议结构
Button(control.title, systemImage: control.symbol) { /* 选择待确认操作 */ }
    .labelStyle(.iconOnly)
    .buttonStyle(.glass)
    .confirmationDialog(/* 当前按钮的确认状态 */)
```

以上为结构示意，不是已编译的补丁。当前按钮已有 accessibilityLabel，不能把它误报为“没有 VoiceOver 标签”。

### `ios/Pony/Components.swift:65`、`ios/Pony/VehicleView.swift:88`

**较低优先级：重要单位和控制名称使用 caption，需要原生大字号和可读性检查。**

目前采用的是系统字号，并非外部字体，已经符合基础方向。但系统字号本身不保证页面可读性。可以把操作名称及关键数据说明提升到 footnote/subheadline，结合实际窗口宽度验收；不能在没有原生截图的情况下宣称具体布局已经溢出。

```swift
// 当前重要操作说明
Text(control.title).font(.caption)

// 可考虑的排版调整
Text(control.title).font(.footnote)
```

## 采用方式

优先使用仓库顶层的 `swiftui-pro/SKILL.md` 及其完整 `references/`、`agents/`、`assets/`。另一个嵌套技能入口包含 `${CLAUDE_SKILL_DIR}` 路径，是不同工具的入口形式，不能只复制该入口而丢失引用文件。

建议先按项目采用并记录提交版本，再按功能需要读取对应引用文档。保留其“只报告真实问题”和“无关现代化另行建议”的规则，不为了满足风格偏好进行大规模无关重构。

本次优先顺序：**完成工程与模型迁移 → 原生构建 → 修正控件交互与工具栏 → 在真实系统中检查字体和各种尺寸 → 性能优化。**

## 来源

- [技能入口与审查流程](https://github.com/twostraws/SwiftUI-Agent-Skill/blob/f9800713b24580bc444931949aad4519128605e8/swiftui-pro/SKILL.md)
- [设计规则](https://github.com/twostraws/SwiftUI-Agent-Skill/blob/f9800713b24580bc444931949aad4519128605e8/swiftui-pro/references/design.md)
- [辅助功能规则](https://github.com/twostraws/SwiftUI-Agent-Skill/blob/f9800713b24580bc444931949aad4519128605e8/swiftui-pro/references/accessibility.md)
- [导航和弹窗规则](https://github.com/twostraws/SwiftUI-Agent-Skill/blob/f9800713b24580bc444931949aad4519128605e8/swiftui-pro/references/navigation.md)
- [现代 API 和工具栏](https://github.com/twostraws/SwiftUI-Agent-Skill/blob/f9800713b24580bc444931949aad4519128605e8/swiftui-pro/references/api.md)
- [Apple 工具链、SDK 与语言模式](https://developer.apple.com/xcode/system-requirements)
