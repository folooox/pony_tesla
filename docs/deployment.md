# 当前服务器部署

历史部署快照日期：2026-10-15。

**2026-10-22 原生登录更新：本文表格和旧安装步骤属于历史快照，不代表当前登录服务状态。已有原生登录服务应按 [登录修正指南](login-update.zh-CN.md) 更新 issuer/JWKS；不要直接运行下方全量安装命令覆盖线上配置。**

## 地址和服务

| 项目 | 当前值 |
| --- | --- |
| 域名 | `tesla.ponypro.party` |
| Cloudflare DNS | A → `129.150.56.139`，仅 DNS，TTL 自动 |
| HTTPS | Let's Encrypt；当前证书到期日 2027-01-11 |
| 反向代理 | 已有 `nginx` Docker 容器 |
| 独立站点配置 | `/home/web/conf.d/tesla.ponypro.party.conf` |
| 后端 | `pony-tesla.service`，系统用户 `pony-tesla`，已开机启用 |
| 程序目录 | `/opt/pony-tesla` |
| 后端监听 | `172.20.0.1:8787`（已有 Docker 网桥） |
| 当前状态 | HTTPS 正常；缺 Tesla Client ID / Client Secret；没有真实车主令牌 |
| 历史数据库 | `/opt/pony-tesla/.private/history.sqlite`，0600，所有者 `pony-tesla` |

2026-10-15 已部署连接准备状态、最近车况缓存、行程历史 API 与 168 小时清理。线上 32 项只读部署检查和桌面/手机两个尺寸的浏览器检查通过。生产库没有填入模拟数据；真实行程接收器及原生用户会话尚未实现。接口契约见 [后端 API](backend-api.md)。

部署脚本针对当前服务器及已有 Docker 网络编写。迁移服务器时需重新检查网桥、代理挂载和证书目录。

## 更新代码或凭据

仓库根目录的 `.env` 是安装脚本的配置来源。用户之后取得 Tesla 应用凭据时，通过本地编辑器填入该文件，不发到聊天或提交 Git。安装脚本同步配置到 `/opt/pony-tesla/.env`，所以不要只修改运行目录后又用旧的仓库配置重装。

```sh
npm test
npm run test:browser
sudo bash deploy/install-backend.sh
npm run test:deployment
npm run test:live-browser
```

脚本使用已有密钥；检测公钥不一致时停止。运行中的令牌位于 `/opt/pony-tesla/.private/tokens.enc.json`，不会被仓库中的测试文件覆盖；生产 `history.sqlite` 同样不会被安装脚本覆盖。已有本地注册记录时会同步 `registration.json`，readiness 会核对其应用、域名和公钥绑定。不要重新生成加密密钥后覆盖现有配置，否则历史令牌无法解密。Cloudflare DNS 令牌未复制到运行目录。

`npm run register` 仍需在应用获批、凭据就绪后单独执行。部署成功不代表 Tesla 合作伙伴注册成功。

## 证书与续期

- Certbot 原证书：`/etc/letsencrypt/live/tesla.ponypro.party/`。
- Nginx 使用的证书副本：`/home/web/certs/tesla.ponypro.party/`。
- 续期部署钩子：`/etc/letsencrypt/renewal-hooks/deploy/pony-tesla.sh`，来源为仓库的 `deploy/renew-certificate.sh`。
- 已有 `certbot.timer` 负责续期；该钩子只处理本域名，复制新证书，校验并重载 Nginx。
- `/.well-known/acme-challenge/` 保留 HTTP webroot 验证，其余 HTTP 请求跳转 HTTPS。

本次签发、部署钩子实际执行和以下续期演练均已成功：

```sh
certbot renew --cert-name tesla.ponypro.party --dry-run --non-interactive
```

Certbot 非交互续期可能带随机等待；这不代表命令卡住。

## 运行状态

```sh
systemctl status pony-tesla.service
systemctl status certbot.timer
curl --fail https://tesla.ponypro.party/healthz
```

`needs_configuration` 表示服务在运行但应用配置未齐。`ready_for_authorization` 仅代表配置齐备，不能证明 Tesla 接受了凭据或账号已授权。是否已保存账号令牌由受保护的 `/api/status` 显示。

受保护的 `/api/readiness` 显示各阶段状态。历史清理在服务启动时及每小时执行，查询会立即排除已到期数据；通过 `journalctl -u pony-tesla.service` 检查是否出现清理失败提示。不要在日志里添加访问令牌、OAuth 回调参数或完整轨迹。当前没有历史备份任务；以后增加备份需同时制定到期删除规则。

本轮更新前的程序代码保存在 `/opt/pony-tesla/rollback-backend-20261015`，仅包含后端源码，不含密钥或历史数据库。必要时停止服务、恢复该目录的源码再启动；不要删除 `.private`。旧代码不会提供新增历史 API。

本次部署只新增本站 Nginx 配置，未启动服务器上旧的系统 Nginx 服务，也未修改其他站点。
