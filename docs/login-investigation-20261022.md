# 登录回调排查（2026-10-22）

## 结论

线上服务 `/opt/pony-tesla` 尚未包含 GitHub `fix/direct-login-20261022`（`ac99416`）中的第三方身份校验修正。界面笼统的 `Native authorization invalid or expired` 不代表实际超时。

线上日志在 2026-10-20 16:34 和 2026-10-21 10:55（UTC+8）记录 `identity KEY_MISSING`，并记录 `FRESH_THIS_ATTEMPT RAW_ABSENT GLOBAL_RAW_ABSENT`。这表明回调已通过 state/Cookie 检查和令牌交换，随后无法在所选公钥源中找到签名密钥。

## 当前部署与候选代码差异

| 配置 | 当前部署 | 最新登录分支 |
| --- | --- | --- |
| JWKS | `https://auth.tesla.cn/oauth2/v3/discovery/keys` | `https://auth.tesla.cn/oauth2/v3/discovery/thirdparty/keys` |
| issuer | `https://auth.tesla.cn/oauth2/v3` | `https://auth.tesla.cn/oauth2/v3/nts` |

排查时直接读取 Tesla 中国区第三方发现文档，确认其 `issuer` 与 `jwks_uri` 均与候选代码一致：
https://auth.tesla.cn/oauth2/v3/thirdparty/.well-known/openid-configuration

通用公钥集与第三方公钥集的签名密钥 ID 不同。候选代码还同步使用第三方 issuer 映射账号，避免只修公钥后继续发生 `ISSUER` 错误。

历史日志未保留令牌或其密钥 ID，因此不能据此证明历史令牌必然能通过新公钥验证；更新后仍需真实登录闭环验证。

## 验证与下一步

- 已拉取 main 至 `6941fb4`，并建立本地 `fix/login-callback-investigation`，基于远端登录候选分支 `ac99416`。
- 在该分支执行 `npm test`：121 项通过，0 失败，包括第三方 issuer/JWKS 固定配置、签名校验、错误 issuer 拒绝和完整模拟登录回调。
- 本次排查未修改线上服务、重启进程或操作车辆，也未完成真实 Tesla 登录验收。
- 后续应备份当前运行文件，在生产部署中应用并测试上述第三方校验修正，再重启服务。此问题位于后端身份校验，针对这一修正无需重新构建 iOS。
- 从 App 重新发起全新授权；旧回调 state/code 为一次性，不能刷新旧错误页面复用。
- 验收需完成 Tesla 登录、回到 App、建立应用会话；失败时检查最新的 `[pony-native-auth]` 枚举日志，不记录令牌或完整回调 URL。
