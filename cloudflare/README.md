# Cloudflare 调度器：部署与维护

## 源码来源与边界

`worker.js` 初次入库时原样来自用户于 2026-10-19 提供的控制台运行源码，原始版本 SHA-256 为 `38ca5258cc3d3272d8d960d71821818611a222a184ecef95af967502fa89a254`。2026-10-25 仓库源码新增课表起止时间校验，已与原始字节不同；该哈希仅标识初始来源。尚未连接 Cloudflare 核对或部署此变更。维护时应以仓库和控制台实际差异为准，避免继续在两处分别修改而失去追踪。

架构、Python 监听配置、合工大同步、Android ICSx⁵ 以及服务器部署见 [项目 README](../README.md)。Worker 只负责提交 GitHub Actions，无法保证实际签到或答题结果。

## 实际配置

| 项目 | 位置 | 当前行为 |
| --- | --- | --- |
| `REPO` | 源码常量 | `frewily/Free-From-RainClassroom`；Fork 部署需改为自己的公开仓库 |
| `GITHUB_API` / `SCHEDULE_URL` | 源码常量 | 从 `REPO` 构建；工作流为 `python-app.yml`，课表为 `main/data/course_schedule.json` |
| dispatch 分支 | `triggerGitHub()` 请求体 | `{"ref":"main"}`；改分支需同时核对 Raw URL 与工作流位置 |
| `AUTO_DISPATCH` | 源码常量 | 当前为 `true`；只控制 Cron，不能通过环境变量覆盖 |
| `TRIGGER_WINDOW_MINUTES` | 源码常量 | 15，含开始、不含第 15 分钟，且必须早于课程结束 |
| `RECORD_TTL` | 源码常量 | 14 天 / 1,209,600 秒 |
| `GITHUB_TOKEN` | Cloudflare Secret | 目标仓库 fine-grained PAT |
| `TEST_TRIGGER_KEY` | Cloudflare Secret | 两个 POST 接口的独立 Bearer 密钥 |
| `TRIGGER_KV` | Cloudflare KV binding | 已被 GitHub 接受的触发请求记录，非业务成功记录 |
| 普通环境变量 | Wrangler `vars` | 当前源码没有使用，因此示例为空 |

将 `AUTO_DISPATCH` 改成环境变量有利于运维切换，但必须先约定布尔解析、缺省值和兼容已有部署的方式，还会改变生产配置依赖。本次不做此改动。源码中“先保持 false”的注释是原文，实际有效常量为 `true`。

## 从零部署

以下命令供部署者配置自己的实例时使用；维护本仓库时无需执行真实部署。示例使用 Wrangler **4.151.1**，本地校验环境为 Node.js **24.15.0**；需安装符合所用 Wrangler 要求的 Node.js / npm。Worker 和离线测试都不需要第三方运行依赖，仓库不新增 Node 依赖清单。

### 1. 准备 GitHub 与课表

1. Fork / 克隆仓库并获取最新 `main`，启用 GitHub Actions。在仓库 Settings → Secrets and variables → Actions 配置 `SESSION`、所需的 `AI_KEY` / `ENNCY_KEY`、`FILTERED_COURSES`，以及自己的监听窗口或合工大同步凭据，详见项目 README。
2. 核对 `data/course_schedule.json` 是自己的已筛选课表。Worker 只读取 `classes`，不校验 `semester` 或用 `selected_courses` 再筛选；Python 才会按启用模式校验学期和监听名单。修改课程筛选后先刷新课表，保持两端一致。
3. 监听工作流仅有 `workflow_dispatch`。课表刷新工作流仍有 GitHub `0 18 * * *` 定时，相当于北京时间次日 02:00；并不是所有 GitHub 定时都关闭了。同学期、同名单会跳过教务登录，临时调课不会每日自动同步。
4. 在 GitHub Settings → Developer settings → Personal access tokens → Fine-grained tokens 创建 PAT：Resource owner 为目标仓库所有者；Repository access 仅选择目标仓库；Repository permissions 额外授予 **Actions: Read and write**，Metadata 保留必需只读权限。仅 dispatch 不需要 Contents 写权限。检查有效期及组织审批要求，安排到期轮换。

先在尚未改动 Worker 的仓库根目录执行原样源码的离线检查（不会访问远端）：

```bash
node --input-type=module --check < cloudflare/worker.js
node --test cloudflare/worker.test.mjs
```

测试断言针对入库版本的 `REPO`、`ref: main` 和 `AUTO_DISPATCH=true`；主动变更这些常量或接口后，需同步相应测试预期。特别是将开关改为 `false` 后，期望 Cron 发起请求的用例将不再成立；先确认原样测试通过，再制作自己的演练部署副本。

### 2. 准备独立配置

在仓库根目录执行：

```bash
cd cloudflare
cp wrangler.jsonc.example wrangler.jsonc
```

编辑 `wrangler.jsonc`：将 `name` 改为自己账户下全新的开发 Worker 名称，确认 `main` 为相对配置文件的 `worker.js`。示例兼容日期为 `2026-10-01`，这是新实例的基准，不代表已有生产实例的兼容日期。`workers_dev: true` 提供测试 URL，无需配置自己的域名。

编辑自己部署副本的 `worker.js`，把 `REPO` 改为自己的仓库，并在首次验证时明确将 `const AUTO_DISPATCH = true` 改为 `false`。这是部署者主动选择演练模式；仓库保存的用户原始源码仍为 `true`。设置 `env.AUTO_DISPATCH` 或 Wrangler 的同名 `vars` 不会起作用。`/test` 即使在此演练模式也会真实触发。

示例配置以 `.example` 结尾，不会被 Wrangler 当作常规配置自动发现；务必复制为 `.jsonc` 再使用。配置中的 Namespace ID 是占位符，必须填写。`triggers.crons` 默认是空数组，主动修改为 `["*/5 * * * *"]` 后才注册 Cron。此默认值仅用于新实例，不适合直接覆盖生产配置。

`wrangler.jsonc`、本地 `.dev.vars` / `.env*`、`.wrangler`、`dist` 和 `node_modules` 已忽略。发布前仍需检查 Git 差异，不提交凭据。不要把 PAT 或测试密钥写入 `vars`；本项目没有其他必须配置的普通环境变量。

### 3. 登录并创建 KV

以下命令在 `cloudflare/` 下执行：

```bash
npx wrangler@4.151.1 login
npx wrangler@4.151.1 whoami
npx wrangler@4.151.1 kv namespace create TRIGGER_KV --config wrangler.jsonc
```

确认 `whoami` 显示正确账户。把创建命令返回的 Namespace ID 填入 `kv_namespaces[0].id`，`binding` 保持 `TRIGGER_KV`。多个账户时需在本地配置中指定正确 `account_id`。新实例使用独立 Namespace，不连接生产 KV。

也可以在 Cloudflare 控制台创建 Namespace，再在 Worker 的 Bindings 中选择 KV Namespace，变量名设为 `TRIGGER_KV` 并绑定该 Namespace；仅创建而未绑定会失败。

### 4. 检查、创建实例和设置 Secrets

原样源码测试见步骤 1。修改部署副本后再次做 JavaScript 语法检查；若修改了行为，先更新测试预期再运行相关测试。在 `cloudflare/` 确认新 Worker 名称、自己的仓库、独立 KV、Cron 为空且源码开关关闭后执行：

```bash
npx wrangler@4.151.1 deploy --dry-run --config wrangler.jsonc --outdir .wrangler/dry-run
npx wrangler@4.151.1 deploy --config wrangler.jsonc
npx wrangler@4.151.1 secret put GITHUB_TOKEN --config wrangler.jsonc
npx wrangler@4.151.1 secret put TEST_TRIGGER_KEY --config wrangler.jsonc
```

`--dry-run` 只做本地配置 / 打包检查，不会上传，且不会验证凭据、Namespace 是否实际存在或云端权限。后面三条会创建或修改远端实例；Secrets 通过交互提示输入，不把真实值写进命令历史。`secret put` 会生成并部署新版本，因此迁移生产前也需核对其目标。

第一轮部署的 Cron 为空，无 Secrets 时两个 POST 路由会返回 500；配置完毕后再验证。控制台部署同样可行：创建全新 Worker，将 `worker.js` 作为 ES module 粘贴到编辑器，填写相同的两个 Secrets、绑定 KV，先不添加 Cron。不要设置自动部署或绑定本项目现有生产实例进行试验。

### 5. 验证后开启自动调度

先使用下方健康检查和 `/preview`，检查自己的课表匹配与 KV 状态。若需要验证真实 dispatch，由部署者确认目标仓库及影响后调用一次 `/test`，到 GitHub Actions 核对新 run；它与 Cron 去重互不关联。

准备正式运行时，主动将自己的源码常量 `AUTO_DISPATCH` 改为 `true`，将本地配置的 `triggers.crons` 改为 `["*/5 * * * *"]`，检查后重新部署。或者在控制台对应 Worker 中添加该 Cron Trigger，并部署开启常量的源码。Cloudflare Cron 使用 UTC；北京时间 08:00 为 UTC 00:00，每 5 分钟表达式在两种时区都表现为每 5 分钟。

同一业务目标只启用一个调度来源，避免新旧 Worker 同时提交。Cloudflare 配置传播和 Cron 执行可能延迟；GitHub Runner 也可能排队，安装依赖约需 75 秒是经验值，不构成准点保证。真实课程窗口必须单独验收。

## 接口验证

以下示例在 bash / zsh 中使用。将 `WORKER_URL` 改成自己的 Worker 地址，通过隐藏输入临时读取测试密钥；不要开启 `set -x`、不要分享带密钥的终端记录。这里使用的是 `TEST_TRIGGER_KEY`，不是 GitHub PAT。

```bash
WORKER_URL='https://YOUR_WORKER.YOUR_SUBDOMAIN.workers.dev'
printf '输入测试接口密钥：'
IFS= read -r -s TEST_KEY_VALUE
printf '\n'
```

### GET /：健康检查

```bash
curl -i "$WORKER_URL/"
```

返回 200 和 `RainClassroom Scheduler is running!`。无需鉴权；它不检查课表、KV、Secrets 或 GitHub API。

### POST /preview：演练

```bash
printf 'Authorization: Bearer %s\n' "$TEST_KEY_VALUE" |
  curl --fail-with-body -i -X POST "$WORKER_URL/preview" \
    --header @- \
    --header 'Content-Type: application/json' \
    --data '{"at":"2026-10-20T08:00"}'
```

`at` 为北京时间，格式严格为 `YYYY-MM-DDTHH:mm`，不加 `Z` 或 `+08:00`。示例日期只是演示，改成自己 JSON 中的实际排课时间。Authorization 使用请求头，通过标准输入传给 curl，避免密钥进入进程命令参数。

成功返回 JSON，例如（仅示意，不代表目前 KV 内容）：

```json
{
  "date": "2026-10-20",
  "time": "08:00",
  "dispatchEnabled": false,
  "results": [
    {"start":"08:00","courses":["示例课程"],"status":"would_dispatch"}
  ]
}
```

`would_dispatch` 表示时间匹配且 KV 未记录；`already_dispatched` 表示已有记录；无匹配时 `results: []`。即使源码常量为 `true`，预览也不调用 GitHub、不写课程记录，但会读取真实课表和 KV，不是完全隔离的沙盒。缺少 PAT 即使不触发也会返回 500，缺少 KV 同样失败。

用 07:59、08:00、08:14、08:15 等时间检查边界；08:15 不再匹配 08:00 开始的课程。日期应使用有效日历日期；当前 JavaScript 对部分不存在的日期会归一化，详见后面的已知限制。

### POST /test：真实触发

**由部署者主动决定执行，会产生真实 Actions run；不应放入日常只读验收脚本。** 此接口忽略课表、KV 和 `AUTO_DISPATCH`，连续调用会连续提交请求，不需要请求体。

```bash
printf 'Authorization: Bearer %s\n' "$TEST_KEY_VALUE" |
  curl --fail-with-body -i -X POST "$WORKER_URL/test" --header @-
```

GitHub 返回 204 后，Worker 返回 200 和 `GitHub Actions dispatch accepted!`。这仅代表提交被接受，还需在目标仓库查看运行记录、排队和步骤结果；更不代表签到或答题成功。`/test` 不会为课程写 KV 记录，因此之后的 Cron 仍可能针对该课程提交。

使用后清除当前 shell 中的临时密钥变量：

```bash
unset TEST_KEY_VALUE
```

其他路径返回 404；`/test` 和 `/preview` 使用非 POST 返回 405；缺少配置返回 500；配置齐全但 Bearer 密钥不正确返回 401；时间字段缺失、格式不符或无法解析返回 400。无效 JSON / `null` 请求体和其他处理异常当前返回通用 500，不返回原始错误正文。

## 已知限制与审查

风险等级表示对调度正确性和维护的影响；下表注明后续源码修复，线上部署状态仍需独立核对。

| 风险 / 等级 | 触发条件及结果 | 建议 / 现有边界 |
| --- | --- | --- |
| **起止时间已修复，其余字段仍待校验** | 2026-10-25 仓库源码在调度前校验整份课表的 `start` / `end`：要求 `00:00–23:59` 的 `HH:mm`，且结束晚于开始。任一时间无效会终止本轮检查，Cron 抛出明确错误，`/preview` 返回 500；均不触发 Actions、不读写 KV | 日期等其他字段未做完整格式校验；不支持用 `24:00` 或跨日倒序区间表示结束时间。此行为与当前 Python 生成的同日时间格式一致；尚未部署线上 |
| **中：KV 竞态，非原子锁** | 两次并发调用都读到空键，都会提交；最终一致性可能扩大重复窗口。日期与原始开始时间字符串构成键，同一开始时间的课程合并，课程名不影响键 | 使用单一调度实例、统一时间格式、观察重复 run。当前不是严格去重；无须本次引入分布式锁 |
| **中：dispatch 已接受但 KV 写失败** | GitHub 返回 204 后 `put` 抛错，调用失败但 Actions 已创建，后续 Cron 可能再次提交；已离线复现 | 先核对 Actions 历史，不盲目重放；记录失败和提交时间。KV 有键也只代表提交接受，不会自动追踪或重试业务失败 |
| **中：网络结果不确定 / 缺少应用层超时** | 课表和 dispatch 的 `fetch` 均无显式 AbortSignal 或重试策略，受平台生命周期限制；GitHub 收到请求但响应丢失时不会写 KV，下一轮可能重复 | 后续可增加有界超时、脱敏结果记录，但超时不代表服务端未接收，不能简单无限重试。下一轮补触发仍限于 15 分钟窗口 |
| **中：测试密钥泄露可反复启动任务** | `/test` 有精确 Bearer 校验，缺失或错误密钥会拒绝；持有密钥者可反复调用，无速率限制、KV 检查或 Cron 开关保护 | 使用独立高强度密钥并轮换，限制分享范围；必要时评估额外访问限制，暂不更改接口行为。关闭 AUTO_DISPATCH 不能禁用 `/test` |
| **中：Worker 与 Python 的课表判断不同** | Worker 不检查 `semester`、不再按 `selected_courses` 过滤，只信任已筛选的 `classes`；Python 在启用课表模式时检查当前学期及筛选名单 | 以自己的当前学期课表为准，先刷新再预览；同学期临时调课需主动维护；不要继承他人课表直接启用 Cron |
| **低：预览日期和错误分类不严格** | `2026-02-30T08:00` 会被 JS 归一化为 03-02；无效 JSON / `null` 返回 500。预览不触发，但结果可能让人误判 | 使用有效日期，后续可增加日历日期往返校验、将输入问题统一为 400 |
| **低：错误日志不完全可控** | 正常路径没有输出 PAT / 测试密钥，也不接触 SESSION；HTTP catch 直接打印 `error.message`，解析错误可能包含请求片段，第三方异常文字也未经脱敏 | 不向接口提交凭据正文；后续改用固定错误分类并脱敏。不能因为正常路径无密钥就宣称任何异常日志都安全 |

其他已核对行为：

- GitHub **仅 HTTP 204** 视为接受，200 / 401 / 403 / 404 / 422 / 5xx 都抛错且不写 KV；本轮未自动重试，按时段可能由后续 Cron 再检查。Cron 没有 HTTP 路由的 Secrets 预检，缺 PAT 会在调用 GitHub 时失败。
- 课表 HTTP 失败、JSON 无法解析、`classes` 非数组、缺失时间字段、部分错误记录会中止并抛错；不是所有异常都安全拒绝，NaN 情况见上表。多个 slot 按顺序处理，后一个 slot 失败不能撤回前面的提交。
- `chinaTime()` 使用时间戳加 8 小时后取 ISO 的日期与分钟，不依赖服务器本地时区；跨日、跨年已离线验证。当前时间来自 `new Date()`，不是 `controller.scheduledTime`，迟到的 Cron 仍按实际执行时间检查，超过窗口不补跑。
- `/preview` 明确向 `checkSchedule` 传 `false`，不调用 dispatch / KV put；但要读取 KV，因此会返回已触发状态。GET 健康接口公开，无法用它证明调度正常。
- 并发组仅限制 Actions 执行数量，不能替代按课程去重；同一个 Worker 内不同开课时间只要都在窗口内，也可能提交多个 run。不会把 dispatch 记录自动转为业务成功。

后续可讨论剩余课表字段校验、输入 / 异常日志规范化及有界超时，再经明确约定评估环境变量开关、测试入口限制。起止时间校验已在仓库源码完成，其他项未捆绑修改。

## 更新已有 Worker

1. 获取远端最新代码，检查当前分支、工作区和差异。对照控制台导出源码、名称、账户、兼容日期、KV、Cron、Secrets 名称及路由；备份必要配置，禁止在公开文件写 Secret 值。
2. 修改仓库源码后先运行离线测试和 dry-run；本次只纳入源码，不代表生产环境自动更新。控制台方式需人工更新代码，Wrangler 方式需明确目标配置。
3. 从控制台迁移到 Wrangler 前，建立完整的本地配置并核对现有设置。示例的空 Cron 列表可能移除已有触发器，错误 KV 可能丢失原去重视图；`vars`、绑定、路由也应逐项核对，不能直接套用。不要同时运行两个正式调度器。
4. 只有部署者确认后才执行 `deploy --config wrangler.jsonc`；`secret put` 也是远端变更。保持一条明确的部署路径，避免网页修改和本地部署相互覆盖。
5. 部署后核对生效代码和绑定，用健康检查、预览和日志验收。真实 `/test` 和真实课程 Cron 需单独观察；出现错误先核对已有 Actions run，再决定回退或补跑，避免重复提交。

## 验证状态

- **用户已报告的线上结果：** Cron `*/5 * * * *` 能执行，GET 公共 JSON、北京时间匹配、`/preview`、KV 读写成功；受保护的 `/test` 返回 200，GitHub Actions 实际启动并执行。用户表示常量 `AUTO_DISPATCH=true` 已部署。
- **初次入库时本地已验证：** 附件与当时的 `worker.js` 逐字节一致；JavaScript 语法；示例 JSONC 解析及 Wrangler 4.151.1 官方配置 schema；复制为 `.jsonc` 后的本地 dry-run 打包；44 项 Node 离线测试。测试覆盖 UTC+8 / 跨日、窗口边界、同时间合并、KV、HTTP 鉴权与路由、失败及已知风险复现，所有 HTTP 和 KV 均为模拟，不依赖真实凭据。
- **2026-10-25 本地已验证：** 新增起止时间校验后，JavaScript 语法及 55 项 Worker 离线测试通过，当前本地课表通过修改后 Worker 的模拟预览；HTTP 全部拦截为本地数据。未重新运行 Wrangler 打包，也未部署或验证线上 Worker。
- **尚未完成：** 独立核对控制台线上源码、使用真实 Cloudflare / GitHub 账号从零部署验收、真实课程窗口的 Cron → Actions → 持续监听、线上并发去重和长期稳定性，以及实际签到答题结果。离线模拟不证明平台时序和 KV 一致性保障。
- **原有工作流：** 本次不修改 GitHub Actions YAML、Python 业务代码、课表或生产配置；原有课表同步与日历提醒保留。

## 常见故障与参考

- Worker HTTP 200 / GitHub 204 后没有课堂结果：分别查看 Runner 排队、Python 是否进入监听窗口、SESSION 是否过期及业务日志。
- 预览无匹配：核对 Raw URL、`main`、实际 `classes` 日期与起止时间，确认未超过 15 分钟且尚未下课；有 KV 记录时应看 `already_dispatched`，不要误认为未匹配。
- POST 返回 500：先检查两个 Secrets、KV 绑定、有效 JSON，查看脱敏错误日志；健康检查 200 不能排除这些问题。接口失败不能排除 GitHub 已收到请求。
- API 401 / 403 / 404 / 422：检查 PAT 有效期、目标仓库与 Actions 权限、组织审批 / 限流、工作流路径和 `main`；不要把错误响应原文含凭据地公开。
- Cron 不运行：核对是否仍为示例中的空数组、是否部署到了正确实例，查看 Cloudflare 调度日志并等待配置传播。

部署命令和格式参考 [Wrangler 配置](https://developers.cloudflare.com/workers/wrangler/configuration/)、[Wrangler Worker 命令](https://developers.cloudflare.com/workers/wrangler/commands/workers/)、[KV 入门](https://developers.cloudflare.com/kv/get-started/)、[Secrets](https://developers.cloudflare.com/workers/configuration/secrets/)、[KV 一致性](https://developers.cloudflare.com/kv/concepts/how-kv-works/) 和 [GitHub workflow dispatch API](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)。后续升级 Wrangler 时重新核对命令和配置，不应假定 schema 检查就等同于生产部署成功。
