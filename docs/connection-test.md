# 真实账号连接测试

更新日期：2026-10-15。当前尚未完成真实车辆连接。

## 普通车主与应用开发方

最终用户使用自己的普通 Tesla 车主账号，在 Tesla 官方页面登录并授权 Pony Tesla。用户不需要申请开发者应用，也不用提供开发者密钥。

Pony Tesla 作为开发方，需要先在 Tesla 中国开发者平台创建应用并取得凭据。Client ID 标识用户正在授权的应用，Client Secret 只保留在我们的后端。不能用一个普通账号的用户名和密码直接替代这一步，也不能收集用户密码或从官方 App 提取令牌来代替正式授权。

用户正在申请开发者应用，尚未配置 Client ID / Client Secret。HTTPS 后端已部署至 `https://tesla.ponypro.party`，公钥可公开读取，后台页面受访问密码保护。

## 当前实现和边界

- 单车主、单进程的内部连接测试工具，不是面向公众的多用户后端。
- 引导至 `https://auth.tesla.cn/oauth2/v3/authorize` 登录。
- 只请求 `openid offline_access vehicle_device_data vehicle_location`。
- 后台交换授权码，AES-256-GCM 加密保存令牌；浏览器不获得访问令牌或刷新令牌。
- 授权 state 与浏览器 HttpOnly/Secure Cookie 绑定，10 分钟有效且只能消费一次。
- 串行刷新令牌，成功后原子保存轮换后的令牌。
- 获取授权车辆列表，用户选择车辆后读取一次状态并检查 `fleet_status`。
- 车辆休眠/离线时只显示实际状态；没有唤醒、开锁、开空调等控车接口。
- 单次在线读取结果展示在受保护后台并持久化最近车况；缓存接口不会触发新的车辆请求。
- 新增行程数据库及 7 天查询/清理机制，已用模拟批次验证；工具仍不配置 Fleet Telemetry，也不采集连续行程。完整 API 与未实现边界见 [后端 API 文档](backend-api.md)。

页面所需的 `owner` 测试账号是我们后台的访问保护，与 Tesla 账号无关。后续正式 iOS 产品不向车主暴露这一测试账号流程。

## 需要应用所有者完成的准备

### 1. 注册开发者应用

访问 [Tesla 中国开发者平台](https://developer.tesla.cn/)，用自己控制的账户申请应用。按平台要求如实填写主体信息；具体资格与审核结果由 Tesla 决定，不能预先保证个人申请一定获批。

可使用的应用说明草案：

> Pony Tesla 是面向中国大陆 Tesla 车主的 iOS 应用。用户通过 Tesla 官方 OAuth 授权后查看自己的车辆状态、位置、充电数据和行程记录。第一阶段仅验证只读车辆数据接入，后续按需申请控车权限。计划将行程与轨迹保存在服务器，并滚动保留最近 7 天。

首次请求只读车辆数据和位置相关权限。后续控车权限需再申请并由用户授权。

获批后的 Client ID 和 Client Secret 填入后端 `.env` 或部署服务的密钥管理配置，不发到聊天、不提交 GitHub。

### 2. 准备一个可持续使用的 HTTPS 后端域名

当前已完成的实际配置：

| 项目 | 配置 |
| --- | --- |
| 允许的源 URL / 后端地址 | `https://tesla.ponypro.party` |
| 允许的重定向 URI | `https://tesla.ponypro.party/oauth/callback` |
| 允许的返回 URL | 暂留空 |
| 公钥路径 | `https://tesla.ponypro.party/.well-known/appspecific/com.tesla.3p.public-key.pem` |

开发者平台的允许来源和回调地址须匹配实际部署。普通 GitHub 仓库地址不能充当这个动态回调服务。

本地开发默认监听 `127.0.0.1:8787`。当前生产服务监听 Docker 网桥的 `172.20.0.1:8787`，由已有 Nginx 容器反向代理，未新增公网后端端口。公钥路径公开可读；其余后台页面需要本工具的访问密码。本站代理关闭访问日志，不记录 OAuth 回调查询参数、Authorization 头或 Cookie。运维步骤见 [部署说明](deployment.md)。

### 3. 初始化并配置后端

在仓库根目录使用 Node.js 24.5+：

```sh
npm run setup
```

只运行一次。生成 `.env`、P-256 密钥对和随机加密密钥，不把秘密打印到终端。已有配置时拒绝覆盖。随后通过本地编辑器或部署平台配置：

- `TESLA_CLIENT_ID`
- `TESLA_CLIENT_SECRET`
- `PUBLIC_ORIGIN`

生成的 `ADMIN_PASSWORD` 是后台 `owner` 账号密码；`TOKEN_ENCRYPTION_KEY` 用于令牌加密，需稳定保存，否则旧令牌无法解密。Fleet 私钥只留在 `.private/private-key.pem`，服务只公开公钥。

运行：

```sh
npm start
```

配置缺失时 `/healthz` 返回 `needs_configuration`。本地启动成功不等于已有公网 HTTPS 部署，也不等于已连接 Tesla。

### 4. 完成中国区合作伙伴注册

确保 HTTPS 公钥地址已对外可读且应用获批，再运行：

```sh
npm run register
```

该命令校验公网公钥，与中国区交换合作伙伴令牌并调用应用注册端点。它会真实注册应用域名，但不会发送车辆控制命令。

成功后生成本地注册记录；在仓库执行注册后，按部署文档更新服务，使运行目录获得该记录。`/api/readiness` 分开报告配置、注册记录、授权、存储和遥测状态，不能把某一阶段成功视为全部接通。

### 5. 使用普通车主账号测试

1. 在浏览器打开正式配置的 HTTPS 后端地址，输入本工具 `owner` 测试账号。
2. 点击“前往 Tesla 登录并授权”。
3. 在 Tesla 官方页面使用普通车主账号登录，完成验证并同意授权。
4. 回到后台测试页，获取车辆列表，选择国产 2022 款 Model 3。
5. 在车辆在线时点击“读取车况”。若休眠，可先在官方 App 或车上使其在线。
6. 核对电量、充电、温度和位置是否与实车相符；检查固件与钥匙配对状态。

授权被撤销或刷新返回 401 时，工具提示重新授权，不会无限重试。断开 Tesla 授权可在官方账户的第三方应用授权管理中执行。移除本地令牌文件不等于撤销 Tesla 端授权。

## 成功标准

需要分别证明以下状态，不能用某一级代替下一级：

1. **应用已注册**：中国区应用注册成功。
2. **账号已授权**：官方登录回调成功，后端安全保存令牌。
3. **车辆可访问**：授权车辆列表包含目标车。
4. **车况读取成功**：收到有效字段，并与实车核对。
5. **持续遥测成功（下一阶段）**：完成虚拟钥匙配对、遥测服务配置，车辆向服务器持续推送数据。

自动化测试使用模拟 Tesla 响应，不使用真实账号，不能替代上述实测。HTTPS 地址、公钥发布与自动续期已经完成；当前尚缺开发者应用凭据、区域注册和车主本人登录授权。详见 [功能测试报告](test-report.md)。

## 正式发布前的后端升级

本工具仅允许一个车主、一个服务进程。正式发布前，需要应用自己的用户会话、按用户隔离的持久化存储、密钥管理、分布式令牌刷新锁、授权撤销与删除流程，以及遥测采集和数据到期清理；不能直接将内部测试工具开放给所有车主。

## 官方依据

- [创建应用、公钥与区域注册](https://developer.tesla.cn/docs/fleet-api/getting-started/what-is-fleet-api)
- [普通车主 OAuth 授权与令牌刷新](https://developer.tesla.cn/docs/fleet-api/authentication/third-party-tokens)
- [合作伙伴令牌](https://developer.tesla.cn/docs/fleet-api/authentication/partner-tokens)
- [合作伙伴注册端点](https://developer.tesla.cn/docs/fleet-api/endpoints/partner-endpoints)
- [车辆列表、车况和 Fleet 状态](https://developer.tesla.cn/docs/fleet-api/endpoints/vehicle-endpoints)
