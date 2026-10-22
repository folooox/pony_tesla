# 原生登录修正：拉取、部署和复测

更新日期：2026-10-22。适用于已有原生登录后台的 `tesla.ponypro.party` 环境。

## 这次修正是什么

Tesla 登录成功后，后台可能显示 `Native authorization invalid or expired`。排查到的线上日志是 `identity KEY_MISSING`：旧代码取错公钥集，而非实际会话超时。详细证据和结论边界见 [排查记录](login-investigation-20261022.md)。

`backend/native-auth.mjs` 必须同时使用：

```text
JWKS = https://auth.tesla.cn/oauth2/v3/discovery/thirdparty/keys
THIRD_PARTY_ISSUER = https://auth.tesla.cn/oauth2/v3/nts
```

签名校验、issuer 比较及账号身份映射均使用此第三方配置。不能只修改公钥 URL，也不能跳过签名、nonce、audience 或有效期检查。配置来源是 [Tesla 中国区第三方发现文档](https://auth.tesla.cn/oauth2/v3/thirdparty/.well-known/openid-configuration)。授权与令牌交换仍使用现有中国区地址。

## 其他电脑如何拉取

已有仓库先运行 `git status --short`，如有自己的修改先提交或保存，再执行：

```sh
git fetch origin
git switch fix/direct-login-20261022
git pull --ff-only origin fix/direct-login-20261022
git log -1 --oneline
```

首次拉取可直接指定分支：

```sh
git clone --branch fix/direct-login-20261022 https://github.com/folooox/pony_tesla.git
cd pony_tesla
```

默认 `main` 尚未包含原生登录候选，单独执行 main 的 `git pull` 不会获得本修正。`archive/owner-pairing-20261022` 为已停止的配对实验，`snapshot/root-current-20261022` 是混合工作快照，均不应代替此登录分支。

拉取只更新源码，不会自动更新 `/opt/pony-tesla` 的运行文件。Mac 上针对本次后端校验修正无需重新构建 iOS；首次取得此原生登录候选源码则仍需在 Xcode 构建该 App。工程自身的构建与模拟器验收需单独完成。

## 已有原生后台如何更新

以下为现有单进程 systemd 部署的定向更新，只替换身份校验模块。先确认正在使用 `/opt/pony-tesla/backend/native-router.mjs` 和 `/opt/pony-tesla/backend/native-auth.mjs`，服务名为 `pony-tesla.service`。全新服务器或仅有旧网页后台的环境不适用，应先完成 [原生会话契约](native-session-contract.md) 中的配置和完整后端安装。

在服务器上拉取上述分支，在仓库根目录使用 Bash，逐段执行并确认成功后继续。需要 Node.js 24.5+：

```bash
npm test
test -f /opt/pony-tesla/backend/native-router.mjs
test -f /opt/pony-tesla/backend/native-auth.mjs
sudo systemctl is-active pony-tesla.service
diff -u /opt/pony-tesla/backend/native-auth.mjs backend/native-auth.mjs
```

`diff` 有差异时退出码为 1 是正常结果；此命令用于人工核对。预期变化为第三方公钥 URL、issuer 常量、issuer 校验和身份映射。若发现其他定制逻辑，应先合并这些逻辑，不能直接覆盖。

备份旧模块，将候选模块及回归测试放入临时目录，以线上 Node 和线上 core 模块进行离线测试。测试使用临时数据库和合成令牌，不读取生产凭据：

```bash
set -euo pipefail
pony_auth_backup="/opt/pony-tesla/rollback-native-auth-$(date +%Y%m%d-%H%M%S)"
sudo install -d -m 0700 "$pony_auth_backup"
sudo cp -p /opt/pony-tesla/backend/native-auth.mjs "$pony_auth_backup/native-auth.mjs"
echo "回滚目录：$pony_auth_backup"

pony_auth_check=$(mktemp -d)
trap 'rm -rf "$pony_auth_check"' EXIT
cp backend/native-auth.mjs backend/native-auth.test.mjs "$pony_auth_check/"
cp /opt/pony-tesla/backend/core.mjs "$pony_auth_check/"
/opt/pony-tesla/bin/node --test "$pony_auth_check/native-auth.test.mjs"
```

上一步通过后安装并重启：

```bash
sudo install -m 0644 backend/native-auth.mjs /opt/pony-tesla/backend/native-auth.mjs.next
sudo mv /opt/pony-tesla/backend/native-auth.mjs.next /opt/pony-tesla/backend/native-auth.mjs
sudo systemctl restart pony-tesla.service
sudo systemctl is-active pony-tesla.service
cmp backend/native-auth.mjs /opt/pony-tesla/backend/native-auth.mjs
curl --fail https://tesla.ponypro.party/healthz
```

不要重新运行 `npm run setup`、替换 `.env`、更换加密密钥或删除 `.private`。旧全量安装脚本会从仓库 `.env` 覆盖运行配置，不适合仅应用这次修正。已有 `NATIVE_ENABLED=1` 和 `NATIVE_APPROVED_ORIGIN` 应保持正确；后者必须等于 `PUBLIC_ORIGIN`。Tesla 注册回调仍为 `https://tesla.ponypro.party/oauth/callback`，App 回调仍为 `pony-native://auth`。

账号按验证后的 issuer+subject 隔离。历史上如曾以旧 issuer 建立账号，新 issuer 可能对应不同的本地账号；本次不自动合并账号或迁移其历史数据。

## 登录验收

1. 从 App 发起全新登录，完成 Tesla 官方授权，再自动回到 App。不能刷新旧错误页或复用已消耗的 state/code。
2. 确认 App 能建立自己的账号会话。需要时手动加载车辆列表；本次不要求控车或持续采集。
3. 如果仍失败，只提取安全诊断枚举：

   ```sh
   sudo journalctl -u pony-tesla.service --since '10 minutes ago' --no-pager -o cat | rg '^\[pony-native-(auth|key-check)\]'
   ```

`KEY_MISSING` 表示签名密钥不匹配；`ISSUER` 表示签发者不匹配；`WRONG_BROWSER` 是浏览器绑定失败；`PENDING_EXPIRED` 才是待完成请求超时。不能把所有错误都当成超时，也不要关闭校验来放行。不要粘贴完整回调 URL、Cookie、身份令牌或访问令牌。

`npm test` 已在本次候选分支通过 121 项，包含第三方配置和模拟授权闭环。另使用线上 `/opt/pony-tesla/bin/node` 和线上 `core.mjs`，在隔离临时目录验证修正模块，40 项身份与会话测试通过；未替换运行文件或重启线上服务。离线通过及健康接口成功均不能证明真实登录成功，真实登录需要上述 App 端闭环验收。

## 回滚

如新模块导致服务异常，在同一 Bash 会话使用之前记录的备份目录恢复。换终端后先将 `pony_auth_backup` 设置为实际备份目录：

```bash
test -f "$pony_auth_backup/native-auth.mjs"
sudo install -m 0644 "$pony_auth_backup/native-auth.mjs" /opt/pony-tesla/backend/native-auth.mjs.next
sudo mv /opt/pony-tesla/backend/native-auth.mjs.next /opt/pony-tesla/backend/native-auth.mjs
sudo systemctl restart pony-tesla.service
sudo systemctl is-active pony-tesla.service
```

回滚会恢复旧版身份校验及其登录问题，不会删除数据库或撤销 Tesla 授权。
