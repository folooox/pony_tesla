# Pony Tesla

[English](README.en.md) | 简体中文

面向中国大陆 Tesla 车主的第三方 iOS 应用，首个验证车型为国产 2022 款 Model 3。使用 SwiftUI、MapKit、Swift Charts 和原生 Liquid Glass，关注日常控车、充电和最近 168 小时的行程。

> 当前原生客户端使用合成数据，不会控制真实车辆。后端已实现连接测试与历史 API，但原生登录、真实指令、持续遥测和后端会话尚未接入。当前 Mac 环境已通过 iOS 27.1 SDK 构建，并以 iPhone 17（iOS 27.0）为主完成四个主页面、异常场景、控车确认、行程回放、充电流程及显示适配测试；iPhone Duo（iOS 27.1）仅用于兼容性冒烟。实机与真实 Tesla 联调仍待执行。

## 在 Mac 上开始

需要 **Xcode 27、iOS 27 SDK 和 iOS 27 模拟器**，最低运行版本 iOS 27.0。Mac 系统必须满足所装 Xcode 的 [Apple 官方要求](https://developer.apple.com/xcode/system-requirements/)。只运行原生演示不需要 Node.js、Tesla 凭据、后端或付费开发者账号。

```sh
git clone https://github.com/folooox/pony_tesla.git
cd pony_tesla
bash ios/mac-build.sh
open ios/Pony.xcodeproj
```

在 Xcode 选择 **Pony → iOS 27 模拟器 → Run（⌘R）**。脚本检查工具链，运行逻辑检查，并构建不签名的模拟器 App；不自动启动模拟器。

**首次安装 Xcode、模拟器下载、实机签名、日志位置与故障排查，请按 [Mac 编译完整流程](docs/mac-build.zh-CN.md) 操作。**

## 已实现与边界

| 模块 | 当前状态 |
| --- | --- |
| 原生车辆、行程、充电、我的 | 模拟交互、快捷控制保存、地图、回放、备注、CSV、7 种测试场景 |
| 原生核心与状态管理 | 已有 Swift 测试；以 [验证记录](ios/VALIDATION.md) 为准 |
| Tesla 连接工具 | 中国区 OAuth、加密令牌存储与刷新、车辆列表和单次车况读取；真实授权待验证 |
| 历史后端 | SQLite 车况缓存、行程查询/详情/备注/删除/CSV、168 小时清理；隔离模拟采样流程 |
| 待完成 | 原生真实会话与控车、连续采集、实车联调、剩余手动模拟器项目、实机验收、发行图标与上架资料 |

模拟车况、备注和历史在退出后重新生成；快捷控制布局通过 UserDefaults 保存。旧 `screenshots/` 和 `prototype/` 是早期网页方向，不代表当前原生界面。

车辆首页现已接入原生 RealityKit 交互样机，支持外观／座舱、独立开合状态及模拟加热。当前程序化模型尚未达到官方外观精度；精细车辆资产和塔迪斯／光轮主题的交付要求见 [车辆体验设计](docs/design/vehicle-experience.md) 与 [3D 资产规范](docs/design/model-asset-contract.md)。

## 可选：本地后端

需要 Node.js 24.5+（使用内置 SQLite）。无第三方运行依赖：

```sh
npm test
npm run test:history-flow
npm run setup
npm start
```

`setup` 仅首次运行，生成 `.env` 和 `.private/`，不会覆盖原配置。编辑 `.env` 完成应用配置；默认本地端口 8787，后台用户名 `owner`，密码在本地 `.env`。真实 OAuth 还需要 Tesla 开发者应用凭据与匹配的 HTTPS 域名，详见 [连接准备](docs/connection-test.md)。不要提交凭据、授权数据、私钥或运行数据库。

浏览器测试另需开发依赖：

```sh
npm ci
npx playwright install chromium
npm run test:browser
```

Linux 如缺浏览器系统库，使用 `npx playwright install --with-deps chromium`。原生构建不依赖 npm 安装。

## 仓库与文档

- `ios/`：原生工程、PonyCore 本地 Swift Package、逻辑检查与 Mac 构建脚本。
- `backend/`：单车主连接工具、历史服务与网页后台。
- `deploy/`：Linux 服务、Nginx、证书续期与部署检查。
- [Mac 编译流程](docs/mac-build.zh-CN.md) / [English Mac guide](docs/mac-build.en.md)
- [原生工程说明](ios/README.md)、[模拟器验收清单](ios/SIMULATOR-CHECKLIST.md)、[验证记录](ios/VALIDATION.md)
- [产品范围](docs/product-requirements.md)、[后端 API](docs/backend-api.md)、[部署维护](docs/deployment.md)、[后端测试记录](docs/test-report.md)

本项目为独立第三方项目，与 Tesla 无隶属或官方认可关系。仓库尚未指定开源许可证。
