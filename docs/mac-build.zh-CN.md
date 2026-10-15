# Mac 编译与首次运行

[English](mac-build.en.md) | [返回 README](../README.md)

目标是先在 Mac 编译并运行当前模拟版，再进行实机验收。这里是待执行流程，不是 Mac 构建通过记录。原生客户端不需要启动后端或配置 Tesla 密钥。

## 1. 准备 Xcode

1. 安装完整 **Xcode 27**，包含 iOS 27 SDK。仅安装 Command Line Tools 不够。Mac 兼容性按 [Apple 官方系统要求](https://developer.apple.com/xcode/system-requirements/) 核对。
2. 启动 Xcode，接受许可并完成首次组件安装。
3. 在 Xcode → Settings → Components 下载 iOS 27 Simulator Runtime；通过 Window → Devices and Simulators 创建对应 iPhone 模拟器。
4. 在终端确认选中的工具链；若 Xcode 位于其他路径，修改下面第一行：

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
xcodebuild -version
xcrun --sdk iphonesimulator --show-sdk-version
swift --version
xcrun simctl list devices available
```

需要 iOS Simulator SDK 27+、Swift 6.2+。工程最低 iOS 27.0，不要为了绕过 SDK 缺失直接降低 deployment target。

## 2. 下载并构建

```sh
mkdir -p ~/Developer
cd ~/Developer
git clone https://github.com/folooox/pony_tesla.git
cd pony_tesla
bash ios/mac-build.sh
```

已有仓库时在工作区干净的情况下执行 `git pull --ff-only`，不要重复克隆到原目录。私有仓库需要当前 GitHub 账号具备访问权限。

脚本先执行 PonyCore 测试、AppStore 检查、语法和工程检查，再用共享 Pony scheme 构建模拟器 App，禁用签名。它不下载 Xcode、不改变签名、不启动模拟器。首次运行需等待 Xcode 完成本地包解析；PonyCore 来自仓库，无远程 Swift Package。

产物与日志（均不会提交 Git）：

- App：`ios/DerivedData/Build/Products/Debug-iphonesimulator/Pony.app`
- 逻辑日志：`artifacts/mac-build/logic.log`
- 构建日志：`artifacts/mac-build/build.log`

## 3. 在模拟器运行

```sh
open ios/Pony.xcodeproj
```

选择顶部 **Pony** scheme、iOS 27 的 iPhone 模拟器，按 **⌘R**。不要选择 My Mac 或真机作为首次构建目标。模拟器不需要签名团队。

默认 `normal` 场景。可在“我的 → 模拟器测试”切换，也可在 Product → Scheme → Edit Scheme → Run → Arguments → Arguments Passed On Launch 添加两个独立参数：`-scenario`、`missingData`。支持 `normal`、`empty`、`asleep`、`offline`、`error`、`expired`、`missingData`。测试后删除参数以恢复默认启动。

按 [模拟器清单](../ios/SIMULATOR-CHECKLIST.md) 检查四个主页面、指令确认、曲线回放、CSV、备注、异常场景和辅助功能。地图/地点搜索需要网络；其余演示不需要真实账号。退出后模拟历史和备注重建，快捷控制顺序保留。

## 4. 在 iPhone 上运行

1. iPhone 需 iOS 27+，连接 Mac、信任电脑，并按系统提示启用 Developer Mode。
2. 在 Xcode Settings → Accounts 添加自己的 Apple 账号。
3. 选择 Pony target → Signing & Capabilities → Automatically manage signing，选择自己的 Team。
4. 如 Bundle ID 被占用，将 `party.ponypro.Pony` 改为自己唯一的标识；不要提交他人的 Team 或签名资料。
5. 选择已连接的 iPhone，按 ⌘R。设备运行仍是模拟数据，不会控制车辆。

个人账号的签名能力和期限以 Xcode/Apple 提示为准。TestFlight/App Store 还需开发者计划、图标、发行签名和商店资料；当前流程不代表可以直接上架。

## 5. 常见问题与交接

| 现象 | 处理 |
| --- | --- |
| `xcodebuild` 指向 Command Line Tools | 重新执行步骤 1 的 `xcode-select`，或设置当前终端的 `DEVELOPER_DIR` 为正确 Xcode 路径 |
| 找不到 iOS 27 SDK / destination | 安装对应 Xcode 和 simulator runtime；运行 `xcodebuild -project ios/Pony.xcodeproj -scheme Pony -showdestinations` 查看可用目标 |
| PonyCore 找不到 | 确保克隆完整仓库且保留 `ios/PonyCore` 相对位置，打开的是 `ios/Pony.xcodeproj` |
| SwiftUI API、actor isolation 或链接报错 | 保存完整日志及首个错误，这是首次 iOS SDK 验证要解决的内容；不要将仅语法检查视为构建通过 |
| 提示签名失败 | 模拟器使用脚本的不签名构建；真机配置 Team 与唯一 Bundle ID |
| 旧缓存导致异常 | 先关闭 Xcode，再只删除生成目录 `ios/DerivedData`，重新运行脚本 |
| `xcodebuild test` 无测试 | App scheme 没有 XCTest/UI Test target；使用 `bash ios/check-logic.sh` 运行现有逻辑检查 |

完成后在 [验证记录](../ios/VALIDATION.md) 追加 Mac 型号/架构、macOS、Xcode、SDK、模拟器型号/系统、提交 SHA（`git rev-parse HEAD`）、构建结果和待修问题。截图需来自真实模拟器或设备，不能使用旧网页截图。构建失败时保留两个日志和首个错误；成功后再进行外观验收与后续真实服务集成。
