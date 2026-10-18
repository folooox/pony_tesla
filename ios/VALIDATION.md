# 原生重构验证记录

## 2026-10-17：Mac 构建与 iPhone 17 功能验证

范围：共享业务逻辑、状态流程、Xcode 工程结构、无签名模拟器构建及 iPhone 17 主设备功能验证。本轮没有修改或重启运行中的后端。

环境为 Apple Silicon Mac（arm64）、macOS 27.0.1（26A434）、Xcode 27.1（27A9275）和 iOS Simulator 27.1 SDK。主功能验证设备为 iPhone 17（iOS 27.0）；iPhone Duo（iOS 27.1）仅作安装、启动和车辆首屏兼容性冒烟。工程基于 `b692a8d`，并包含本次 Xcode 27.1 兼容修复。

| 项目 | 结果 | 验证边界 |
| --- | --- | --- |
| PonyCore Swift Testing | 20 / 20 通过 | 实际编译并执行共享模型、规则和模拟 actor |
| AppStore 状态流程 | 15 / 15 通过 | 实际编译并执行界面使用的状态管理类 |
| SwiftUI 语法与工程结构 | 通过 | PBX 属性列表、7 个源文件引用、本地包、共享 scheme 及 frontend parse |
| 原生 iOS App 构建 | 通过 | Debug、generic iOS Simulator、关闭代码签名 |
| 构建产物 | 通过核验 | `arm64` + `x86_64`，Bundle ID `party.ponypro.Pony`，版本 `0.1`，最低 iOS 27.0 |
| iPhone 17 主页面 | 通过 | 车辆、行程、充电、我的均可进入；保存四个主页面原生截图 |
| 快捷控制与模拟指令 | 通过 | 增删、最多 4 个、排序、冷启动持久化及默认恢复；锁车、空调、哨兵确认、结果与日志一致 |
| 行程功能 | 通过 | 7 天汇总、日期筛选、详情、回放/暂停、速度/功率/电量曲线，以及标签和备注保存后重开 |
| CSV 导出 | 部分通过 | 单段 CSV 已生成并核对模拟标记、行程、标签和备注；iOS 文件提供器没有完成最终落盘 |
| 充电功能 | 通过 | 上限草稿与 70% 应用、暂停、开始及结果提示；重置后恢复默认 80% |
| 7 种测试场景 | 通过 | normal、empty、asleep、offline、error、expired、missingData；禁用、空态、重试及缺失值符合预期 |
| 数据时效保护 | 通过 | 正常数据静置超过 2 分钟后阻止命令并提示刷新；实际下拉刷新手势尚未验证 |
| 导航与设置入口 | 通过（有问题） | 全部控制、空调、定位地图、车辆设置及行程管理可达；地图搜索返回真实结果且选择后提示发送导航未接入，但清空查询后旧结果仍显示 |
| 系统外观与辅助功能 | 部分通过 | 浅色/深色、最大辅助字号可滚动、增强对比度、无障碍名称与单位通过；iPhone 17 横屏车辆页存在安全区裁切；减少动态效果/透明度未验证 |
| iPhone Duo 兼容性 | 冒烟通过 | iOS 27.1；成功安装、启动并显示车辆页和原生标签栏 |
| 实机与 Tesla 联调 | 未执行 | 未配置设备签名；真实会话、指令及遥测尚未接入原生客户端 |

构建命令为 `bash ios/mac-build.sh`；脚本在系统仍选择 Command Line Tools 时会自动使用标准位置的 `/Applications/Xcode.app`。App 位于 `ios/DerivedData/Build/Products/Debug-iphonesimulator/Pony.app`，逻辑检查与 Xcode 构建日志分别位于 `artifacts/mac-build/logic.log` 和 `artifacts/mac-build/build.log`。iPhone 17 四个主页面截图为 `pony-iphone17-vehicle.png`、`pony-iphone17-trips.png`、`pony-iphone17-charging.png` 和 `pony-iphone17-profile.png`；导出内容证据为 `pony-iphone17-trip-export.csv`；Duo 冒烟截图为 `pony-iphone-duo.png`，均位于 `artifacts/mac-build/`。

首次 SDK 构建暴露并修复了 SwiftPM 6.3 构建产物目录变化、macOS 上 `FoundationXML` 的条件导入、不适用于当前 SDK 的 `NavigationLink` 便利初始化、重复工具栏最小化修饰符，以及交互式 Debug 同时构建两种架构导致的本地包模块冲突。完整脚本构建和两个模拟器的安装启动随后均执行成功。

本轮发现三个需要后续处理的问题：地图搜索框的清除按钮会清空查询文字，但不会立即移除旧结果；CSV 内容已正确生成到临时文件，但 iOS 文件提供器没有完成“我的 iPhone”最终落盘；iPhone 17 横屏车辆页左侧指标受安全区裁切，底部内容也有截断。

本轮未执行全部行程 CSV 的最终文件提供器保存、清空模拟历史最终确认、实际下拉刷新手势、快速连续场景切换、减少动态效果/透明度、小屏/iPad，以及实机签名与设备验证。以上边界不能由逻辑测试或已完成的 iPhone 17 覆盖替代，后续按 [模拟器测试清单](SIMULATOR-CHECKLIST.md) 继续记录。

## 2026-10-15：Linux 逻辑与结构检查

环境为 Linux ARM64，使用官方 `swift:6.2` 容器（Swift Testing 输出版本 6.2.4）。测试容器禁用网络，只挂载 `ios/`，不接触服务器凭据或运行数据。模拟器和 iOS SDK 不在该环境中。

| 项目 | 结果 | 验证边界 |
| --- | --- | --- |
| PonyCore Swift Testing | 20 / 20 通过 | 实际编译并执行共享模型、规则和模拟 actor |
| AppStore 状态流程 | 15 / 15 通过 | 实际编译并执行界面使用的状态管理类 |
| SwiftUI 文件语法 | 通过，7 个文件 | frontend parse，不执行 iOS SDK 类型检查 |
| Xcode 工程结构 | 通过 | PBX 属性列表、7 个源文件引用、本地包路径及共享 scheme XML |
| 原生 iOS App 构建 | 未执行 | 需要 Xcode 27 和 iOS 27 SDK |
| 模拟器、实机与 Liquid Glass 效果 | 未执行 | 需要 Mac 验收，未生成原生截图 |
| Tesla 授权、实车指令、遥测及服务器保留 | 未执行 | 原生客户端尚未接入 |

20 项核心测试覆盖：滚动 168 小时边界与跨界行程、按日筛选、缺失能耗和非法里程的汇总、按里程加权能耗、无效采样值、地图和曲线缺口、布局去重与排序、数据时效、CSV 转义与公式前缀防护、指令确认后更新、离线/权限/能力/范围错误、备注清理、并发指令互斥与取消后的恢复。

15 项状态检查覆盖：初始加载、控制可用性、操作确认与日志、失败后保持旧值、布局持久化、备注保存、离线阻止操作及不产生成功记录、授权失效、服务错误、空数据、清空历史、刷新不恢复已清空数据，以及切换场景后丢弃旧请求结果。

这些结果证明被测试的模拟逻辑可运行，不证明 SwiftUI 页面已经在 iOS 上编译或呈现正确。工程结构检查也不能代替 Xcode 的构建设置解析与 SDK 检查。

## 复现 Linux 检查

安装 Swift 6.2+ 后，在仓库根目录执行 `bash ios/check-logic.sh`。若使用 Docker，先准备官方镜像，然后执行：

```sh
docker run --rm --network none --cpus 2 --memory 2g \
  --mount "type=bind,src=$(pwd)/ios,dst=/code" \
  -w /code swift:6.2 bash check-logic.sh
```

测试的所有车辆、轨迹和响应均为合成数据，不需要账号或密钥。构建缓存被 Git 和源码包排除。

模拟器或实机验收时，记录机型、系统版本、通过或失败及截图；尚未运行的步骤不得标为通过。
