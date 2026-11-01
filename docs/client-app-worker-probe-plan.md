# 阶段 0：独立 Worker 的 GitHub 刷新与触发验证

日期：2026-10-27；收尾更新：2026-10-28。状态：已按用户批准的范围完成真实云端功能验证，成功轮撤销与公网入口关闭已核验，本地程序已停止。本文保留原测试范围，并注明执行中的修正。

## 1. 本轮要确认什么

此前已证明独立本机程序可以使用 GitHub App 的设备授权用户令牌，在不发送 Client Secret 的情况下刷新，并且只触发指定仓库。现在验证相同能力是否能在 Cloudflare Workers 中实际运行。

本轮只测试一次请求中的立即刷新与空工作流触发。通过也不等于已经解决定时运行、客户端关闭后的长期调度、刷新令牌持久化、并发刷新或丢失响应恢复。

## 2. 本地已准备的文件

| 文件 | 用途 |
| --- | --- |
| [worker-runtime.mjs](verification/worker-probe/worker-runtime.mjs) | 最终 v3 运行源码；实际部署使用已校验的只读快照 |
| [controller.mjs](verification/worker-probe/controller.mjs) | 本机配置页、GitHub 设备授权、单次云端调用、运行观察和撤销检查 |
| [worker.test.mjs](verification/worker-probe/worker.test.mjs) | 使用合成凭据和模拟 GitHub 响应验证边界 |
| [离线验证摘要](verification/client-s0-worker-preparation.json) | 初始准备与最终离线检查；不含真实凭据 |
| [真实运行摘要](verification/client-s0-worker-runtime.json) | 云端刷新、任务结果、次数与清理证据 |

使用已有 Node.js 和系统 curl，没有安装 Wrangler、SDK 或第三方包。最终 20 项 Node 模拟检查通过；它们只说明测试代码满足相应检查，真实 Cloudflare 运行另有证据。旧 `worker.mjs` 保留为早期诊断文件，当前验证程序和测试均使用 `worker-runtime.mjs`，不从旧编辑页复制部署。

## 3. 用户已批准并执行的范围

| 项目 | 本轮明确范围 |
| --- | --- |
| Cloudflare 资源 | 在本人原 Cloudflare 账号创建一个独立 Worker：`rain-client-s0-worker-20261027`；同名资源存在则先停下核对，不覆盖 |
| 部署准备身份 | 由用户通过 Cloudflare 官方控制台创建并复制源码；本轮不扩展 Cloudflare OAuth 客户端权限，也不因此宣称自动部署已通过 |
| Worker 配置 | 只增加此 Worker 的 `PROBE_KEY` Secret，作为随机调用口令；口令由本地程序临时生成，由用户复制到该 Worker |
| GitHub 身份 | 复用 `Rain S0 Scheduler 20261027`，App ID `5489930`；重新进行一次设备授权，权限仍为 Actions 读写、Metadata 只读，安装范围仍只有 target 测试仓库 |
| 凭据传输 | 临时 GitHub 访问令牌和刷新令牌通过 HTTPS 交给主人自己的测试 Worker；刷新后的新令牌对返回本机临时程序，仅供有效性与撤销检查 |
| 凭据存放 | GitHub 凭据仅由程序在内存中处理，不写入 Worker Secret、KV、D1、文件、仓库或结果日志；Worker 唯一持久配置的 Secret 是随机调用口令 |
| 真实任务 | Worker 最多向 `frewily/rain-client-s0-target-20261027` 的 `s0-probe.yml` 提交一次新的 dispatch；control 不参与。本轮成功后 target 的累计运行数应由 1 变为 2 |
| 其他云资源 | 不新增 KV、D1、Durable Object、Cron、DNS、自定义域名或付费套餐配置 |
| 收尾 | 用户撤销本轮 GitHub 用户令牌；本地程序自动复核，随后停止。关闭新 Worker 的 workers.dev 公网入口，保留测试资源，不默认删除 |

生产 `rainclassroom-scheduler`、原有监听工作流、生产凭据、课表和课堂业务不参与。前一轮对两个 GitHub 仓库各最多一次的授权不包含本轮这一次新任务，需以本轮确认范围为准。

## 4. 程序会做什么

1. 本地程序监听 `127.0.0.1:8765`，展示新 Worker 的源码及随机调用口令。口令仅在这一本地页面供用户复制，不发到聊天，不写源码。
2. 用户完成新 Worker 部署和 `PROBE_KEY` 配置，将其 workers.dev 地址填入本地页。
3. 程序只接受指定测试 Worker 名称的 HTTPS 地址。先调用只读 `/ready`，确认部署标识、固定目标仓库及口令匹配；这一检查不调用 GitHub。
4. 用户点击开始，再按设备验证码完成 GitHub 官方授权。此前的测试授权已撤销，因此本轮需要一份新的临时令牌。
5. 本地程序核对账号为 `frewily`，将一次调用标记写入无凭据的本地文件，再向新 Worker 的 `/probe` 发送一次 HTTPS POST。
6. Worker 核对随机口令、请求大小、通过 GitHub 官方原始文件地址取得的空工作流内容摘要、GitHub 身份、App ID、Actions 权限和实际安装范围。范围不是仅 target，或多出代码管理权限，就停止；本地观察最终运行时核对目标提交。匿名 REST 读取曾返回 403，最终未以它作为文件校验的必要前提。
7. Worker 使用 GitHub 官方刷新端点，不发送 Client Secret；验证新令牌可用、身份一致、旧访问令牌返回 401，再向固定 target 工作流提交一次 dispatch。
8. 使用明确的 `2026-03-10` GitHub API 版本，检查成功返回的 200 和运行 ID。Worker 将脱敏摘要及新令牌对通过 HTTPS 返回本机；新令牌对不进入结果文件或浏览器状态页。
9. 本地程序独立检查返回的新访问令牌仍属于同一账号，观察这次空任务是否真正完成，分别保存 Worker 请求结果与 GitHub Runner 结果。

Worker 没有客户端可指定的仓库、工作流或回调地址参数，没有 `scheduled` 处理函数，不记录请求正文、令牌或 GitHub 原始错误响应。

## 5. 重复调用、失败与清理

- 本地程序在发出云端 POST 前，用不可覆盖的新文件记录一次尝试。重启后也不会自动重发。这个保护约束测试控制程序，不等于 Cloudflare 已提供跨实例的恰好一次执行保证。
- 执行中首次请求因 Workers 不支持 `redirect: "error"` 而在刷新和触发前失败。确认没有进入任何刷新或 dispatch 后，归档失败标记，以修复版和新授权受控续测。阶段实际共两次 `/probe` POST，但只有一次进入刷新和调度，总计只新增了一次 target 运行；没有重试未知的调度结果。
- 每个 GitHub 子请求有超时，刷新与 dispatch 都不自动重试。触发请求发出后若响应丢失，结果记为未知，先按唯一 nonce 只读查询运行，不盲目重发。
- Worker 未配置口令或口令不匹配时，不会向 GitHub 发请求。只读 `/health` 仅返回构建标识、公开测试仓库名和口令是否配置，不返回凭据。
- 测试成功后，用户在该测试 App 设置页执行 `Revoke all user tokens`。本地程序每 15 秒只读检查一次刷新后的令牌，观察到 401 才记为已独立核验撤销；检查无需等待 Codex 工具调用，所以额度暂停本身不会阻止它。
- 新凭据最多在本地保留约 15 分钟。超时会丢弃持有值，并把未核实的撤销状态保留为未核实，不补写成功。如果云端刷新后响应完全丢失，无法收到新令牌，也不能用已经因刷新失效的旧令牌来证明新令牌已撤销。
- 新版 Cloudflare 控制台在顶部 **Domains → Worker URL → Production** 开关关闭 workers.dev 公网入口。已关闭该测试入口，并观察公开 `/health` 返回 404；Preview URL 同样处于关闭状态。测试 Worker 和 App 注册保留，后续删除另行处理。

## 6. 通过条件与证据

本轮需要同时看到：真实 workers.dev 部署标识与口令检查成功；Worker 刷新返回 200；新令牌身份一致、旧令牌 401；固定 target dispatch 返回 200；对应唯一 nonce 的 GitHub 空任务成功；本轮没有 control 请求或真实课堂请求。

随后分别记录撤销有效性检查、临时进程停止、公网入口关闭。功能通过和清理状态分别表达，不能以 HTTP 200 或一次绿灯代替长期调度验收。

结果只保存允许的状态字段、HTTP 状态、源码摘要、仓库/运行标识和时间。首次部署通过控制台手工准备，因此本轮仍不证明 Cloudflare OAuth 的资源管理权限、软件内自动部署或跨账号公开授权。

实际结果：2026-10-27，Worker 内刷新与 dispatch 均为 200、旧令牌 401，对应 [空任务 40510756580](https://github.com/frewily/rain-client-s0-target-20261027/actions/runs/40510756580) 成功；target 累计由 1 变为 2，control 仍为 0。成功轮新令牌撤销后自动检查返回 401。2026-10-28 已再次确认公网入口 404，并停止本地 8765、8770 服务。具体证据见[运行摘要](verification/client-s0-worker-runtime.json)和[调试记录](verification/client-s0-worker-debug.json)。
