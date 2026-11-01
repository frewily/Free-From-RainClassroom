# 阶段 0：Cloudflare 账号发现与自动部署验证

日期：2026-10-28。状态：本人账号中的自动部署与实际绑定读取已通过，清理及令牌撤销已独立核验。前两轮分别停在上传 403 和 400／10021；经单独批准改用 Workers Admin，并修正 ES module 上传类型后，第三轮部署、Secret 写入、KV／D1 合成读写及 Worker 实际读取均通过。20 项本地检查与真实云端结果分别记录，尚不覆盖公开跨账号授权、Cron 或 Flutter／Android。

## 对应的软件功能

验证用户在软件完成 Cloudflare 官方授权后，软件能否列出本人加入的账号，在选定账号部署 Worker、配置调用口令和 KV／D1 绑定，并确认 Worker 实际读到存储中的测试数据。之前通过的是 User Details Read 的只读登录，本轮是独立的资源管理验证。

本轮只用随机合成数据，不使用雨课堂 SESSION、课表、邮件密码、GitHub 凭据或真实课堂接口。管理身份仅在本机测试进程持有；Worker 只得到本轮随机调用口令，不得到 Cloudflare OAuth 令牌。

## 首轮已批准并执行的范围

| 项目 | 范围 |
| --- | --- |
| 新私有 OAuth 客户端 | `Rain S0 Cloud Manager 20261028`；保留原来的只读客户端，不修改其权限 |
| 协议 | Response Type 为 Code；Grant type 为 Authorization Code；Token Authentication Method 为 None (PKCE)，S256；不生成或传输 Client Secret，不请求 offline_access |
| 回调 | `http://127.0.0.1:8765/cloudflare/callback`，只监听本机回环地址；重复回调不重复创建资源 |
| 管理授权 | 下表五项，均为 Required；不增加 DNS、账单、账号设置写入、OAuth 客户端管理或 Workers Admin |
| 账号 | 只在本人已知账号 `6081b0f279a7de585cd27b877f1f5335` 中测试；从 Memberships 发现并匹配后才能写入 |
| Worker | 新建一个 `rain-client-s0-deploy-20261028-<12位随机编号>`，不复用生产 Worker 或上一轮保留的调度测试 Worker |
| KV | 新建一个 `rain-client-s0-kv-20261028-<同编号>`，只写一条随机合成值 |
| D1 | 新建一个 `rain-client-s0-db-20261028-<同编号>`，只建一张测试表、写入一条合成记录 |
| Secret | 只在新 Worker 写入随机 `PROBE_KEY`，用于本轮请求验证；不包含任何其他账号凭据 |
| 临时入口 | 临时启用该 Worker 的 workers.dev 入口；Preview URL 保持关闭，不增加自定义域名、路由或 Cron |
| 实际请求 | 本机通过 REST API 写／读 KV 和 D1，再调用新 Worker，核验实际 KV／D1 绑定读取所得数据摘要；只读检查各有上限，不盲目重建资源 |
| 资源清理 | 关闭该 Worker 的 workers.dev／Preview 入口、部署只返回 410 的空实现、清空绑定并删除本轮 Secret；删除本轮 KV 和 D1 后回读确认。保留关闭的空 Worker、客户端注册及脱敏证据 |
| 授权清理 | 程序自动调用已实测可用的 Cloudflare 撤销接口，再检查此前成功的个人信息接口是否返回 401／403；随后丢弃内存引用并停止本地服务。失败则记录待清理项 |
| 安装和 Git | 使用现有 Node.js、系统 curl 和标准库，不安装 SDK／依赖，不修改生产代码、Secrets、DNS、套餐，不提交或推送业务仓库 |

### 首轮实际使用的权限名称（历史范围）

| 控制台分类 | 最终预览名称 | 用途 |
| --- | --- | --- |
| Developer Platform | D1 Write | 新建、合成读写和删除本轮数据库 |
| Developer Platform | Workers Editor | 部署新 Worker、写 Secret、配置绑定和关闭测试入口 |
| Developer Platform | Workers KV Storage Write | 新建、合成读写和删除本轮 namespace |
| Account & Billing | Memberships Read | 读取本人加入的账号，找到目标账号 |
| Account & Billing | User Details Read | 有效性检查和撤销后的同接口拒绝核验 |

控制台的 Workers **Edit** 在最终预览中显示为 **Workers Editor**。注册后已从官方详情核对准确 ID：`d1.write`、`workers-scripts.edit`、`workers-kv-storage.write`、`memberships.read`、`user-details.read`。不能将 API Token 权限名称或 Wrangler 的冒号 scope 猜成第三方 OAuth ID。仓库内模板的 ID 仍为空且校验标记为 false；实际已核对配置仅包含公开 Client ID／scope ID，放在本轮临时目录供程序使用。

这些是所授权账号相应服务的管理权限，程序的资源名／接口白名单不等于平台将令牌限制到一个 Worker、KV 或 D1。首轮未申请 Admin；后续经单独批准仅替换 Workers 权限，详见下文。三轮均不尝试删除 Worker，采用关闭并保留空资源的政策。D1／KV 只清理本轮创建且核对过标识的资源；清理不包括账号中原有数据。

## 验证顺序与失败处理

1. 主人确认上述客户端、五项权限、三个临时资源、临时入口和清理范围后，才提交当前客户端草稿。私有使用不需要本轮修改 DNS 或公开客户端。
2. 读取新 Client ID 及官方 scope ID；核对其对应五项预览名称。认证配置需要精确匹配，不能沿用原只读客户端。
3. 启动本地 PKCE 服务并由主人完成官方授权；程序校验 state 和实际返回的 scope 集合。回调地址需成为表单中的 URL 条目，不能只留在未提交的输入框里。
4. 使用新授权只读请求个人信息、Memberships、Workers 子域与本轮资源存在性；发现账号不符、资源重名或权限不符则停止写入。
5. 当前程序先上传无绑定 Worker，确认编译成功后再新建 KV／D1，做合成写入与回读；随后更新该 Worker 的绑定、写随机调用口令并启用其临时入口。新建请求各只发送一次；响应丢失时先按唯一名称回读，不盲目重发。
6. Worker 只接受带本轮口令的固定 `/probe` 请求，使用固定参数化查询读取测试表；只返回摘要匹配结果，不输出值、令牌或个人资料。KV 传播及新部署可用性的只读等待均不超过 90 秒。
7. 正常结束或普通失败均进入清理。若发现未知绑定等外部改动，保留现场，记录待处理项，不覆盖未知配置或删除仍可能被引用的数据。
8. 自动撤销本轮访问令牌；只有此前个人信息请求成功、撤销返回 200 且之后同接口拒绝时，才记录独立核验撤销。单纯 HTTP 成功、上传接受或本地模拟通过不当作 Worker 已实际运行。

本轮不保存真实管理令牌，不验证 Cloudflare 离线刷新、跨账号公开授权、长期 Cron、GitHub 刷新令牌持久化或 Flutter／Android。它通过后，才有证据支持软件自动创建这组云资源；并不表示完整管理界面或真实课堂运行已完成。

## 已准备的程序与证据

- [Worker 源码](verification/cloudflare-manager-probe/worker.mjs)：固定认证入口、KV／D1 读取、合成摘要比对。
- [验证流程](verification/cloudflare-manager-probe/probe.mjs)：账号检查、资源边界、API 操作、有限回读和资源清理。
- [临时授权与传输](verification/cloudflare-manager-probe/live.mjs)：PKCE、本地回调、现有代理、凭据仅通过子进程 stdin 传输、自动撤销。
- [配置模板](verification/cloudflare-manager-probe/client-config.template.json)：公开 Client ID／scope ID 待注册后核对填写，不包含凭据。
- [本地检查](verification/cloudflare-manager-probe/probe.test.mjs)：当前 20 项通过，包括跨账号／越界阻止、创建响应丢失、Worker 超时、KV 传播等待、删除失败、未知绑定保留、权限续测和中断恢复；实际执行的是同一份 Worker handler，但存储和管理 API 均为模拟。
- [官方资料核对](verification/client-s0-cloudflare-manager-research.json)：最新公开 schema 与文档摘要。完整 27 MB schema 仅留在 `/private/tmp`，不放入仓库。

临时结果与一次运行锁位于 `/private/tmp/rain-client-s0/cloudflare-manager/`。本轮客户端的公开 Client ID 为 `840b60304c633c313f931fc8697f22f3`；通过 PKCE 创建，没有 Client Secret。已确认新客户端为 Private；Client URL 留空，不启动域名验证或修改 DNS。是否实际获得令牌及资源操作结果以运行记录为准，不能把创建成功或本地模拟通过记为资源管理已实测通过。

提交前已核对 Choose optional scopes 显示 All 5 permissions are required；主人明确批准后才点击 Create client，官方返回 Client created。随后在新客户端的 5 scopes 详情中逐项核对上述 OAuth ID。本地授权页为 `http://127.0.0.1:8765/`，由主人完成官方授权，后续测试及撤销自动执行。

## 首轮真实结果与收尾

实际授予的 scope 与上述五项完全一致；Code + S256 校验通过，未发送 Client Secret。个人信息、Memberships 账号发现和资源存在性检查均通过。KV／D1 各新建一个，KV 写入与回读、D1 建表／写入／查询均通过；随后 Worker 上传为 HTTP 403，未创建成功，也没有写 Worker Secret 或启用公网入口。

普通失败后的清理已执行并回读确认：D1 `2f138b02-7ee3-40a0-b150-a9f16cefae1f`、KV `5b8658d0e1b54c7c8f793742e9c764bf` 已删除。访问令牌撤销返回 200，原来返回 200 的个人信息接口随后返回 403，内存引用清除，本地服务正常退出。首轮未留下 Worker；原始记录的 `worker_retained:true` 是当时脚本的默认保留策略标记，实际是否存在以 `worker_created:false` 及回读为准，新版已纠正该状态表示。[首轮 API 记录](verification/client-s0-cloudflare-manager-attempt1.json)与[当前运行摘要](verification/client-s0-cloudflare-manager-runtime.json)。

该结果证明账号发现及 KV／D1 API 管理可行；未证明 Worker 自动部署、绑定读取或整体部署通过。原 403 未记录结构化错误码，精确原因尚未独立确认。官方上传接口列出了 Workers Scripts Write、Workers Admin、Workers Editor 等适用权限，不能只靠名称认定 Editor 在所有场景均不适用；调整权限属于待验证的对照方案，不当作已查明的结论。

## 已单独批准的权限对照续测

在这个私有管理客户端的编辑草稿中取消 Workers / Edit，选择 Workers / Admin，最终预览为 **Workers Admin**。D1 Write、Workers KV Storage Write、Memberships Read、User Details Read 保持原样，共五项 Required。主人明确允许后才点击 Save changes；随后从列表的五项权限详情核对新 ID 为 `workers-scripts.admin`，其他四项 ID 不变。没有创建其他客户端或改为公开可见。

已批准的范围是：

- 允许将同一私有客户端的 Workers Editor 替换为仅 Workers 产品的 Workers Admin；其权限更大，包含所授权账号内 Workers 的创建、修改和删除，并非仅限测试资源，也不是整个 Cloudflare 账号的管理员权限。
- 在原账号重新创建一组带新随机编号的 Worker／KV／D1，执行同样的合成数据部署与绑定读取验证；首轮存储已确认删除，不复用其标识或生产资源。
- 沿用原清理政策：删除本轮 Secret、KV、D1，关闭新 Worker 入口、清空绑定并保留空 Worker；即便新的授权允许删除 Worker，测试程序仍不调用该删除接口。不添加 DNS、Cron、套餐或其他产品权限。
- 自动撤销新令牌并核验，保留前轮证据；新的独立运行锁只接受首轮“Worker 未创建、KV／D1 已删除、清理及撤销独立核验通过”的状态。原 Editor 配置不能静默变成 Admin 配置，启动必须显式选择受控续测分支。

已准备 [Admin 配置模板](verification/cloudflare-manager-probe/client-config.workers-admin.template.json)，仓库模板的校验标记仍为 false，不能直接运行；实际官方 ID 核对后的本轮临时配置已在本机使用。已补充 403 响应类型、OAuth 错误标签、数字／字符串错误码的脱敏记录；不保存原始响应、令牌或合成 Secret 值。

## 第二轮：Admin 权限对照结果

实际授权精确包含 `workers-scripts.admin` 及原来四项权限。账号发现及 KV／D1 合成读写通过，Worker 上传由 403 变为 400，错误码为 10021；Worker 未创建。该轮 KV／D1 均删除并回读，令牌撤销返回 200，原个人信息接口随后返回 403。完整脱敏记录见[第二轮 API 记录](verification/client-s0-cloudflare-manager-attempt2.json)。此对照说明请求进入脚本校验阶段，但不补足首轮 403 未记录的精确原因。

对照官方 multipart 示例，发现上传部分的类型为 `application/javascript`，而 ES module 要求 `application/javascript+module`。只修正该协议差异，并改成编译通过后才分配存储；新增编译诊断只保存脱敏消息。修复前协议用例失败，修复后检查通过；权限和 Worker 源码保持原样。

## 第三轮：自动部署、实际读取与收尾通过

本轮资源编号为 `58f9c6316cc1`。额度暂停后检查到服务已退出，结果仍为 `awaiting_authorization`，没有授权码交换或云端写入记录。恢复分支仅接受这个未开始的状态，同时复核前轮清理／撤销、原 scope、源码摘要及资源名称；保留原锁和快照，以独立排他锁恢复等待并生成新的 PKCE／state。没有重放旧回调或另建一组测试资源。

重新授权后，程序取得与批准范围一致的五项权限，依次完成：

- 上传无绑定 Worker 返回 200；之后创建 KV、D1，API 合成写入和回读均通过。
- 上传正确的 KV／D1 绑定、写入随机 `PROBE_KEY` 并临时开启 workers.dev 入口。Worker 的真实请求返回本轮版本和编号，`kv_matches`、`d1_matches` 均为 true，证明实际读取了两项存储。
- 关闭 workers.dev／Preview、部署空实现、删除 Secret并确认绑定为空；删除 D1、KV 后分别回读确认。保留一个关闭的空 Worker：`rain-client-s0-deploy-20261028-58f9c6316cc1`。
- 访问令牌撤销返回 200，之前返回 200 的个人信息接口随后返回 403；令牌内存引用丢弃。另一次不带凭据的公开入口检查为 404。本地服务随后退出。

20 项本地检查通过，云端成功及收尾以[第三轮 API 记录](verification/client-s0-cloudflare-manager-attempt3.json)和[运行摘要](verification/client-s0-cloudflare-manager-runtime.json)为准。该结果证明本人账号内，软件可使用 PKCE 管理授权自动部署这组资源并验证绑定；尚未验证公开／跨账号授权、Cloudflare 刷新、Cron、长期 GitHub 令牌持久化或 Flutter／Android。没有修改生产资源、DNS、业务代码或提交／推送本业务仓库。
