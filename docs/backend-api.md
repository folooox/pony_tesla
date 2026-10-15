# 后端 API 与存储（第一阶段）

更新：2026-10-15。正式域名 `https://tesla.ponypro.party`。

本阶段仍是**单车主内部连接测试后台**。所有私有接口使用后台 `owner` 的 HTTP Basic 认证；不能把后台密码写进 iOS App，也不能把此认证方式作为公开发布的多用户登录。原生用户会话与 Tesla OAuth 回跳绑定尚待实现。

## 当前状态

- 域名 A 记录、HTTPS、公开公钥、反向代理和常驻服务已完成。
- Tesla Client ID / Client Secret 尚未配置；区域注册和车主授权尚未完成。
- 新增 SQLite 历史存储、车况缓存和下列历史接口。
- 模拟采样流程仅在隔离的临时数据库验证；线上数据库不会灌入演示行程。
- 尚未部署真实 Fleet Telemetry 接收器、稀疏字段合并器或持续采集任务。一次车况读取不会生成行程。

## 接口目录

除健康检查和公钥外，下列数据接口均要求认证，响应带 `Cache-Control: no-store`。修改操作还要求 `Origin` 精确匹配配置域名。

| 方法 | 路径 | 行为 |
| --- | --- | --- |
| GET | `/healthz` | 进程在线与配置是否齐全，不证明授权或采集正常 |
| GET | `/.well-known/appspecific/com.tesla.3p.public-key.pem` | 公开的应用公钥 |
| GET | `/api/status` | 原连接测试页配置与已保存令牌状态 |
| GET | `/api/readiness` | 分开显示配置、公钥、区域注册记录、车主令牌、历史存储、遥测、原生会话状态 |
| POST | `/oauth/start` | 发起 Tesla 官方授权；需要已配置应用 |
| GET | `/oauth/callback` | 浏览器授权回调，要求匹配一次性 state 和 Cookie |
| GET | `/api/vehicles` | 从 Tesla 取得当前授权车辆列表 |
| POST | `/api/probe` | `{ "vin": "…" }`；读取一次车况并保存在线结果，限制 15 秒一次 |
| GET | `/api/v1/vehicles/{vin}/snapshot` | 最近一次已保存车况，不触发 Tesla 请求；无缓存时 404 |
| GET | `/api/v1/history/status` | 可见行程与快照数量、保留期和清理周期 |
| GET | `/api/v1/trips` | 不含采样点的行程摘要列表、分页游标 |
| GET | `/api/v1/trips/{id}` | 完整行程和采样点，过期或不存在返回 404 |
| PATCH | `/api/v1/trips/{id}` | `{ "tag": "通勤", "note": "备注" }`；上限分别为 30、500 个 Unicode 码点 |
| DELETE | `/api/v1/trips/{id}` | 删除行程及其轨迹、备注；仅保留防重放标识直到原保留期届满 |
| GET | `/api/v1/trips/{id}/export.csv` | 即时生成 CSV，含数据来源，不在服务器另存导出文件 |

没有公网采样上传、遥测配置或控车 API。未知路径返回 404，存储未启用为 503；无认证为 401，错误来源为 403，输入错误为 400，请求体过大为 413。PATCH 请求体最大 4096 字节，现有 probe 最大 1024 字节；代理另有 4 KiB 请求体上限。

### 行程查询

- `vin`：可选，完整 VIN。
- `limit`：默认 30，范围 1–100。
- `from`：可选，UTC ISO 8601 时间；筛选结束时间严格晚于该值的行程，不能越过 7 天保留边界。
- `before`：上页返回的 `next_cursor`；按结束时间、ID 倒序分页，同一时间结束的行程也不会漏页。分页时保持其他过滤参数一致。
- 返回 `{ "trips": [], "next_cursor": null, "retention_hours": 168 }`。空数组意味着无已保存行程，不能据此判断账号是否有车辆。

行程摘要包含 `id`、`vin`、`source`、`start`、`end`、`end_reason`、`distance_km`、`net_energy_kwh`、`energy_method`、`gap_count`、`sample_count`、`tag`、`note`。详情包含 `samples`。未知数值为 `null`；净能量可能因回收为负，不应将其当作充电量。功率积分仅为估算。

缓存车况返回 `{ "snapshot": { ..., "cached": true, "stale": true } }`；`stale` 在采集后 120 秒置为 true。`cached` 始终为 true，接口不会主动刷新，不保证此刻车辆在线。离线 probe 不会把旧采样时间改成当前时间。

### 连接状态的含义

`configured` 仅表示本地配置存在；`token_saved` 仅表示保存过令牌。`registration.recorded` 是成功调用注册端点后保存的本地记录，绑定应用、域名及公钥摘要，不代表本次重新向 Tesla 核验了注册。`history.available` 表示数据库已启用，**不代表车辆已在上传数据**。

注册脚本成功后会生成 `.private/registration.json`，不包含合作伙伴令牌或 Client Secret。重新部署时同步到运行目录；凭据值、私钥和访问令牌不出现在 readiness 响应。

## 数据存储与保留

- 数据库：运行目录 `.private/history.sqlite`，正式服务器为 `/opt/pony-tesla/.private/history.sqlite`。文件权限 0600、目录 0700，所有者为 `pony-tesla`。
- 当前 SQLite 历史内容没有字段级加密；账号令牌仍使用独立 AES-GCM 加密存储。历史文件不得作为网页资源或提交仓库。
- 保留窗口为 UTC 滚动 168 小时，完成行程按结束时间计龄，完整轨迹与标签随行程删除。查询即时排除到期数据；启动时及每小时执行物理删除，运行期间最长可能延后约一小时。
- 快照按实际获取时间到期。SQLite 使用 secure_delete 和回滚日志；没有自动历史备份或服务端 CSV 临时文件。文件系统快照、外部备份或用户下载文件不在此数据库删除机制内，未来引入备份需另设过期规则。
- 删除行程后保存仅含 ID、原结束时间的防重放标识；同一批次再次入库不会恢复已删除记录，标识到期清除。
- 服务重启保留数据，安装脚本不复制或覆盖生产历史数据库及车主令牌。单进程、单车主范围不变，尚无按用户隔离和账号切换的数据生命周期。

## 模拟采样与后续接收器接口

`HistoryStore.ingest(vin, source, samples)` 仅为进程内可信入口，未暴露 HTTP 写入。默认数据库拒绝 `simulation` 来源；测试显式允许模拟数据，并始终使用临时目录。

标准化输入单位为 km/h、km、kW、电量百分比，经纬度为有效坐标或一起缺失。每批最多 10,000 点，UTC 时间不得来自未来。算法先排序和去重，相同时间的冲突样本拒绝；D/R 开始、P 结束，D 挡零速不结束。超过 5 分钟断点或 24 小时异常长段切分，停更超时单独标注。相邻点超过 120 秒不积分能耗，保留缺口；缺失功率或里程不靠电量差推算。阈值为测试初值，仍需实车验证。

**当前组装器处理完整批次，不是持续流式采集器。** 未完成段返回 `pending_samples`，不会保存这部分原始点；调用方必须保留完整批次后重试。已归档行程重复提交不重复入库，内容变化返回冲突而非静默改写。正式接收器还需实现持久化待归档样本、断点恢复、稀疏字段合并与时效、迟到数据修订、来源认证及车辆归属校验，不能直接把 Tesla 推送原文传给该函数。

复现隔离流程：

```sh
npm test
npm run test:history-flow
npm run test:browser
```

`test:history-flow` 使用 61 个模拟点，验证临时 SQLite 与真实本地 HTTP 查询和 CSV，结束即删除临时数据库，不读取 `.env`、不连接 Tesla、不操作生产库。

## 接下来仍需要完成

1. 配置获批应用凭据，完成中国区注册，车主在 Tesla 官方页面授权，实测车辆列表与车况。
2. 按车型、固件和配对状态核验 Fleet Telemetry，搭建接收器与可靠的持续归档流程。
3. 建立原生 App 自己的用户会话与安全回调、按用户存储隔离，再对接 SwiftUI 数据层。
4. 按车辆能力逐项实现控车、充电历史与其他功能；当前只读权限不能代表控车已获授权。

官方参考：[应用注册流程](https://developer.tesla.com/docs/fleet-api/getting-started/what-is-fleet-api)、[Fleet Telemetry 架构与先决条件](https://developer.tesla.com/docs/fleet-api/fleet-telemetry)、[Node.js SQLite API](https://nodejs.org/api/sqlite.html)。车辆具体可用性仍以中国区实测为准。
