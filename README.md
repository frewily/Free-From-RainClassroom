# 长江雨课堂定时签到+听课答题
本项目通过 Python 检查正在进行的课堂、签到，并按课程筛选配置监听和处理题目。云端采用 Cloudflare Workers 按课表调度、GitHub Actions 执行；也支持本地 / 服务器运行，以及可选的合工大课表同步和 Android 日历提醒。（本项目针对合工大的课表进行了适配，支持爬取合工大的课表并筛选需要签到的课程名称和日期时间，非合工大也同样可以使用本项目，需要爬取其他学校的课表就尝试自行问问 ai 如何实现吧）

当前默认适配长江雨课堂。其他雨课堂站点的域名、接口和认证方式需自行核对，不能保证只替换 HOST 就能使用。

## 方法1：Cloudflare Workers + GitHub Actions（推荐的云端调度方式）

完全免费且全自动化，但配置流程较复杂，没用过 Cloudflare 的话建议在 ai 指导下配置。

### 架构与运行方式

监听由外部 Cloudflare 定时器按课表发起，GitHub Actions 负责执行 Python 程序。这样绕开了 GitHub 内置 `schedule` 事件可能延迟或漏跑这一环节；不代表绝对准点，也不保证在所有条件下比 GitHub `schedule` 更可靠。仍需考虑 Cloudflare Cron 调度延迟、课表 HTTP 请求、GitHub API 可用性、Runner 排队以及环境初始化。

```text
Cloudflare Cron Triggers：*/5 * * * *
  → Worker scheduled()
  → GET main 分支 data/course_schedule.json（公开且已筛选的课表）
  → 按北京时间匹配当天课程开始后的 15 分钟触发窗口
  → 同一天相同开课时间合并一次触发
  → 查询 TRIGGER_KV：已有记录则跳过
  → 无记录且 AUTO_DISPATCH 开启：POST GitHub workflow_dispatch
  → GitHub 接受请求后写入 KV 记录（TTL 14 天）
  → GitHub Actions 安装依赖、运行 start.py
  → Python 再次判断监听窗口，查课、签到并按课程筛选进入监听
```

**工作流的触发方式不同：**

| 工作流 | 当前触发器 | 职责 |
| --- | --- | --- |
| [python-app.yml](.github/workflows/python-app.yml) | `workflow_dispatch`| 监听执行，可由 Worker API 或 Actions 页面手动启动 |
| [course-schedule.yml](.github/workflows/course-schedule.yml) | GitHub `schedule: 0 18 * * *` 和 `workflow_dispatch` | 可选的合工大课表刷新及 ICS 日历生成 |
| [offline-tests.yml](.github/workflows/offline-tests.yml) | `push` 和 `pull_request` | 独立运行 Python / Worker 离线测试，不触发课堂或邮件业务 |

Cloudflare 每 5 分钟检查一次是否需要**启动任务**；`start.py` 在监听时段内每约 5 分钟**检查课堂**，这是两个独立的周期。进入时段后运行到该时段结束，同一轮不会重复处理同一课堂。当前监听工作流所有调用都属于 `workflow_dispatch`，时段外也会安装依赖并执行一次查课；时段判断格式无效等错误仍会导致任务失败。没有配置外部调度器时，该监听工作流不会自行定时启动。

监听工作流采用同一 `concurrency` 组、`cancel-in-progress: false`：同一时间最多执行一轮，等待中的任务可能被更新的任务替换，不能依赖排队任务接替异常退出的监听。环境初始化和依赖安装约需 75 秒（经验值，非承诺），再叠加排队时间，不能将 dispatch 时间当作实际开始查课时间。

签到记录写入运行环境的 `log.json`，不再提交到公开仓库。Actions 环境是临时的，结束后仓库不保留这些记录；本地可在本机查看。旧提交中的历史记录不会因此消失。

### 部署前：课表与监听配置必须一致

先完成下方 GitHub Actions 基础配置和可选的合工大同步，再配置 Worker。Worker 读取的是公开 JSON，不会读取 GitHub Secrets，也不会根据 `LISTEN_WINDOWS` 推导课表。

- [`data/course_schedule.json`](data/course_schedule.json) 顶层包含 `semester`、`selected_courses`、`classes`；每条 `classes` 仅有 `course`、`date`、`start`、`end`。日期为 `YYYY-MM-DD`，时间为北京时间 `HH:MM`。JSON 已按课程筛选，Worker 按实际 `classes` 调度；仅出现在 `selected_courses` 中但没有实际排课的课程不会触发。
- Actions 仅当 `HFUT_USERNAME` 和 `HFUT_PASSWORD` 两项 Secrets 均已配置时，才自动设置 `COURSE_SCHEDULE_ENABLED=true`。此时 Python 优先读取课表，还会核对当前学期，并用 `FILTERED_COURSES` 再筛选一次。文件存在但学期过旧时不会退回固定时段；文件缺失时才使用 `LISTEN_WINDOWS`。
- 不配置教务 Secrets 时，Actions 按 `LISTEN_WINDOWS` 运行，即使仓库有 JSON 也不会自动启用课表模式。其他学校可以自行维护同格式 JSON 供 Worker 调度，但仍须配置对应的 `LISTEN_WINDOWS` 才能让当前 Actions 在窗口内持续监听；单独添加 JSON 不够。后文的服务器环境可显式设置 `COURSE_SCHEDULE_ENABLED=true`。
- 修改 `FILTERED_COURSES` 后先运行课表刷新工作流，核对提交后的 JSON，再用 Worker 预览，避免两端依据不同数据。不要使用从别人的 fork 继承的课表调度自己的账号。

### Worker 源码与从零部署

本次将用户提供的控制台运行源码原样保存为 [`cloudflare/worker.js`](cloudflare/worker.js)，未重写算法、改动 API 或迁移配置开关。此来源说明不代表已独立连接 Cloudflare 比对线上版本。仓库新增以下文件，不包含真实凭据或生产 Namespace ID：

```text
cloudflare/
├── worker.js                 # 用户提供的原始 Worker 源码
├── wrangler.jsonc.example    # 需复制并填写的部署示例，默认不注册 Cron
├── worker.test.mjs           # Node.js 自带测试工具，HTTP / KV 均为本地模拟
└── README.md                 # 完整部署、接口和风险说明
```

完整操作见 [Cloudflare 部署与维护指南](cloudflare/README.md)：准备自己的仓库和筛选课表 → 配置 GitHub Actions → 创建独立 Worker / KV → 设置两个 Secrets → 验证 `/preview` → 经部署者确认后做真实 `/test` → 开启 Cron。Wrangler 配置需从 `.example` 复制为 `cloudflare/wrangler.jsonc`；本地配置、凭据和生成文件已加入忽略规则。不要对现有生产 Worker 直接套用示例，空 Cron 列表和占位绑定都不代表生产配置。

| 名称 | 实际配置类型 | 用途 |
| --- | --- | --- |
| `GITHUB_TOKEN` | Cloudflare Secret | fine-grained PAT，仅授权自己的目标仓库及 Actions 写权限；不是 Actions 自动注入的同名令牌 |
| `TEST_TRIGGER_KEY` | Cloudflare Secret | `/preview` 和 `/test` 均使用 `Authorization: Bearer <测试密钥>` |
| `TRIGGER_KV` | KV Namespace binding | 保存 GitHub 已接受的课程触发请求记录 |
| `AUTO_DISPATCH` | **worker.js 源码常量，当前为 `true`** | 只控制 `scheduled()` 自动提交；修改需编辑源码并重新部署，设置同名环境变量无效 |
| `REPO`、`GITHUB_API`、`SCHEDULE_URL`、窗口和 TTL | worker.js 源码常量 | Fork 必须核对目标仓库；当前 API 使用 `ref: main` |

当前源码不读取任何普通环境变量，因此示例 `vars` 为空；不将 Secrets 伪装成普通变量。`/test` 无论 `AUTO_DISPATCH` 如何设置都会发起真实 dispatch，且不查课表、不读写 KV。`/preview` 无论该常量如何设置，都只演练，但会真实 GET 课表并读取 KV；两项 Secrets 和 KV 都需要配置。健康检查 `GET /` 只证明 HTTP 入口可响应，不会验证这些依赖。

不要将真实 PAT、测试密钥、`SESSION`、教务密码放进源码、README、URL 查询参数、日志或截图。Worker 不需要雨课堂 `SESSION`；业务凭据保留在 GitHub Actions Secrets。最小权限、Secret 设置及凭据轮换见部署指南。

### Cron 时区、触发窗口与去重语义

Cloudflare Cron 使用 **UTC**，课表匹配使用**北京时间 UTC+8**，日期也必须按北京时间计算。`*/5 * * * *` 在两种时区都表现为每 5 分钟一次；若设置固定时间，北京时间 08:00 对应 UTC 当天 00:00，北京时间 02:00 对应 UTC 前一天 18:00。因此课表刷新工作流的 `0 18 * * *` 表示北京时间次日 02:00，并非北京时间 18:00。

Worker 使用北京时间的日期和分钟，触发窗口为 `[开始时间, 开始时间 + 15 分钟)`，同时要求当前时间早于课程结束时间。08:00 开始的课程在 08:00、08:05、08:14 可匹配，08:15 不匹配；若课程 08:10 已结束，08:10 起也不匹配。超过窗口不会补触发，连续调度失败或延迟可能错过整个窗口。

同一天相同开课时间合并为一次 dispatch，例如 KV 键 `rainclassroom:2026-10-20:08:00`，不按课程名称分别启动。GitHub 接受请求后保存记录，TTL 为 14 天（1,209,600 秒）。该记录表示**已提交且 GitHub 接受触发请求**，并不表示 Runner 已启动或签到答题成功；后续任务失败也不能指望同一记录自动重试。

KV 具有最终一致性，先读再调用 API 再写的过程不具备原子锁语义。并发读取、跨位置可见性延迟、API 接受后 KV 写入失败都可能造成重复；网络超时也可能让提交结果不明确。Actions 的并发组限制执行数量，但不是按课程键的严格去重。需要人工补跑时先检查已有 run，再决定是否手动触发，避免盲目删除 KV 记录反复重放。

### GitHub API 与手动接口

Worker 向以下 GitHub REST API 发送 POST（Fork 应替换所有者、仓库和分支）：

```text
https://api.github.com/repos/frewily/Free-From-RainClassroom/actions/workflows/python-app.yml/dispatches
```

```http
Accept: application/vnd.github+json
Authorization: Bearer <脱敏的 fine-grained PAT>
X-GitHub-Api-Version: 2022-11-28
Content-Type: application/json
User-Agent: rainclassroom-scheduler
```

```json
{"ref":"main"}
```

正常接受 dispatch 时 GitHub 通常返回 **HTTP 204**；现有 `POST /test` 在联调中返回 **Worker HTTP 200**，且 Actions 确实启动并执行。这两个状态码来自不同层级，仅代表请求接收结果，不代表签到答题完成。

- **`POST /preview`：** 使用 `Authorization: Bearer <TEST_TRIGGER_KEY>`，JSON 为 `{"at":"2026-10-20T08:00"}`，`at` 表示北京时间，不带时区后缀。返回 `dispatchEnabled: false`，时段状态可能为 `would_dispatch` 或 `already_dispatched`，无匹配时 `results` 为空。不 dispatch、不写课程记录，但读取真实课表和 KV。
- **`POST /test`：** 使用同样的鉴权，不要求请求体；每次直接 dispatch，无课表 / KV 去重。无课时 Actions 也可能只做单次查课。真实调用应由部署者主动确认后执行。

可复制的 curl 示例见 [接口验证](cloudflare/README.md#接口验证)，勿将 GitHub PAT 当作接口的测试密钥。

### 验证状态与验收步骤

截至 2026-10-19，仓库触发器与 Python 行为已按最新代码核对；下表中的线上 Cloudflare 结果来自用户联调反馈。新增离线测试验证源码行为，不能代替真实课程验收。

| 项目 | 当前证据与边界 |
| --- | --- |
| Cron `*/5 * * * *` 执行 | 已观察 Worker Cron 运行，不等于真实课程已自动启动 Actions |
| 公共 JSON GET、北京时间匹配、`/preview` | 用户已验证成功 |
| KV 读写 | 用户已验证成功，不等于并发严格去重 |
| 受密钥保护的 `POST /test` | 返回 200，GitHub dispatch 实际启动并执行成功 |
| `AUTO_DISPATCH` 正式开关 | 用户表示 `true` 已部署，仍需真实课程窗口验收 |
| 真实课程窗口的 Cron → Actions → 持续监听 | 待实测，不能用手动接口结果替代 |
| 并发去重、长期稳定性、实际签到答题结果 | 线上尚未充分验证；离线已复现 KV 并发竞态和失败后的重复提交风险 |
| 源码与本地验证 | 附件源码逐字节一致；JavaScript 语法、Wrangler 配置 / dry-run 和离线测试通过，详见部署指南 |

建议按以下层次验收，并分别记录时间与结果：

1. 检查 `main` 的 JSON 日期、课程名称、起止时间、当前学期及 Actions 的课程筛选配置。以实际 `classes` 为准，不根据课程名称元数据猜测哪天有课。
2. 按上述接口约定调用受保护的 `POST /preview`，确认模拟时间匹配正确，Actions 没有新 run，课程 KV 没有新增记录。
3. 主动调用一次受保护的 `POST /test`，检查 Worker 状态码及 GitHub Actions 新 run 的事件类型、分支、开始时间和步骤结果。无课时的“手动单次检查课程 / 无课”只能证明执行链路可达。
4. 正式课前确认开关与 Cron 配置。课时到来后记录 Worker Cron 时间、匹配结果、API 接收结果及 KV 键，再核对 Actions 创建、Runner 开始、依赖安装结束和进入监听窗口的时间。下一次 Cron 检查同一键是否跳过，并核对该时段是否出现重复 run。
5. 最后查实际课堂日志中的签到、监听和答题结果；只显示任务绿色或 KV 有键不算业务验收。多次观察后才能评估稳定性，一次正常跳过也不足以证明无并发竞态。

### 排错

| 现象 | 检查方向 |
| --- | --- |
| Cron 没有日志 | 确认已部署、Trigger 存在且属于正确环境，检查配置传播和 Worker 运行错误；HTTP 测试不能代替 `scheduled()` 验证 |
| 有 Cron 日志但不触发 | 核对源码常量 `AUTO_DISPATCH`、Raw URL / main、HTTP 与 JSON 格式、北京时间日期、15 分钟窗口和现有 KV 键；检查课表是否仍是旧学期或未更新筛选名单 |
| `/preview` 或 `/test` 拒绝请求 | 确认使用 POST、`Authorization: Bearer`、已部署的测试密钥及 `/preview` 的 `at` 字段；不要在日志中打印密钥 |
| GitHub API 401 / 403 / 404 / 422 | 检查 PAT 是否过期、授权仓库及 Actions 写权限、组织审批或限流、路径与工作流文件名、Actions 是否启用，以及 `ref: main` 是否存在；按脱敏响应判断具体原因 |
| Worker 报成功但没看到执行 | 核对 API 真正接受的状态与目标仓库，查看 Actions 排队、并发组、运行记录及取消状态；KV 记录不保证后续成功，也不提供自动业务重试 |
| 重复启动 | 检查是否额外手动触发、存在多个 Worker / Cron，以及 KV 最终一致性、先读后写竞态或写入失败；核对键是否按同一天相同开课时间合并 |
| 只单次查课，未持续监听 | 核对实际启动时是否仍在窗口内、两项教务 Secrets、`FILTERED_COURSES`、课表学期及 `LISTEN_WINDOWS`；dispatch 不会强制 Python 忽略监听窗口 |
| 雨课堂 401 / 403 或提示登录失效 | 更新 Actions 的 `SESSION` 后重试；也可能是接口或服务变化。调度器不能修复登录状态；服务器用户更新本地凭据 |
| 临时调课未体现 | 同一学期、相同筛选名单会跳过教务登录，即使手动运行刷新也不会强制重新抓取；核对教务实际安排并自行更新课表，不能把每日工作流当作每日全量同步 |

代码检查还发现课表逐条字段校验不足、请求无应用层超时、预览日期可能被 JavaScript 归一化等限制。本次保留原始行为，风险等级、复现条件及后续建议见 [已知限制与审查](cloudflare/README.md#已知限制与审查)。

GitHub 自带失败通知需在账号通知设置中启用并自行确认。项目另外支持可选的课堂监听开始 / 结束邮件，配置方式见下文；它与 GitHub 账号通知相互独立。

### GitHub Actions 基础配置

1. 按下面教程拿到SESSIONID，或者自己抓APP的包

2. 按图中路径，配置名为SESSION的环境变量，值为SESSIONID的值
![图片1](src/img/Step_1.png)
![图片2](src/img/Step_2.png)

3. 再配置两个secret，AI_KEY和ENNCY_KEY，用于搜题答题，获取方式在末尾

4. 再配置一个 secret `FILTERED_COURSES`，用英文逗号隔开，填写需要监听的课程完整名称。使用合工大课表自动获取功能时不得留空，以免将全部课程公开；名称必须与教务课表一致。

例如：计算机组成原理,数据结构

5. 如使用每周固定时间窗，配置 `LISTEN_WINDOWS` Secret；如果选用合工大课表自动同步，它仅在尚无课表文件时作为可选的后备。例如：

```text
MON=08:00-10:00,14:00-16:00
TUE=09:30-11:30
WED=08:00-09:45
```

使用 `MON` 到 `SUN` 表示周一到周日，时间均为北京时间、24 小时制，格式必须是 `HH:MM-HH:MM`。每天可填多个时段，用英文逗号分隔；不同日期换行，也可用英文分号分隔。每段最长 5 小时，同一天的时段不能重叠，也不能跨午夜；跨午夜请拆成前后两天分别填写。启用合工大同步且课表文件存在后以课表为准，不再使用 `LISTEN_WINDOWS`；即使文件属于旧学期，也不会退回每周固定时间窗。修改 Secret 后仅影响后续运行，已启动的一轮不会自动更换时段。

6. 去 Actions 页面手动点击 `Run workflow` 可检查运行结果。手动触发即使在配置时段外也会单次查课；若在时段内触发，则运行到该时段结束。
![图片4](src/img/Step_4.png)

### 选填：监听开始、结束邮件与日志附件

在仓库 **Settings → Secrets and variables → Actions → Repository secrets** 中配置以下项。它们供 GitHub Actions 使用，不需要添加到 Cloudflare；本地 / 服务器运行时使用同名环境变量。

| Secret | 是否必填 | 内容 |
| --- | --- | --- |
| `EMAIL_HOST` | 启用邮件时必填 | 邮箱服务商的 SMTP 主机，如 QQ 邮箱的 `smtp.qq.com` |
| `EMAIL_USER` | 启用邮件时必填 | 发件邮箱完整地址 |
| `EMAIL_PASS` | 启用邮件时必填 | 邮箱的 SMTP 授权码或应用密码；按邮箱服务商要求开启 SMTP |
| `TO_EMAIL` | 启用邮件时必填 | 收件邮箱完整地址，可与发件邮箱相同 |
| `EMAIL_PORT` | 选填 | 默认 `465`；STARTTLS 通常使用 `587` |
| `EMAIL_SECURITY` | 选填 | 默认 `ssl`；使用 STARTTLS 时填 `starttls`，并配置对应端口 |

例如，QQ 邮箱通常使用 `EMAIL_HOST=smtp.qq.com`、`EMAIL_PORT=465`、`EMAIL_SECURITY=ssl`，`EMAIL_PASS` 填开启 SMTP 时获得的授权码。请在 GitHub Secrets 页面填写真实值，不要将授权码或邮箱凭据贴进源码、日志、Issue 或聊天。

每个实际进入监听的课堂，在同一轮脚本运行中发送两类邮件：

- **开始邮件：** WebSocket 首次收到列表类型的课堂时间线或题目列表后尝试发送（空列表也符合），包含课程名称、课堂编号、北京时间和 Actions 运行链接。这只证明收到相应课堂数据，不保证后续 PPT 获取、题目处理、考勤或评分成功。仅工作流启动、查课成功或 WebSocket 刚建立连接时不会发送；连接重试和重连不会重复发送开始邮件。
- **结束邮件：** 收到教师下课通知、监听窗口结束 / 主程序停止，或监听异常退出时发送，包含起止时间、结束原因、重连次数，以及 UTF-8 文本附件 `listening-log.txt`。附件记录本次已有题目处理的时间、题号、题型、正文、选项、生成结果和提交接口 HTTP 状态 / 异常类型；HTTP 200 不代表答案正确或评分成功。没有处理题目也会明确说明。

同一课堂使用一个后台守护线程，按开始、结束的顺序尝试发送，不在 WebSocket 接收线程中执行 SMTP。结束时最多等候题目处理线程 5 秒，再最多等候邮件线程 5 秒；这两段等待合计最多 10 秒（不计正文格式化等开销）。超时后停止等待，后台 SMTP 可能继续执行，也可能随进程退出而中断，不能据此认定已经取消或投递成功。SMTP 套接字超时为 10 秒，它不是整封邮件的总发送期限。

通知创建、回调、日志记录和收尾中的普通异常均在课堂调用边界隔离，只输出错误类型；失败不自动重试，也不覆盖原有课堂异常。未填写或未完整填写邮件配置时，不创建课堂报告、不额外收集邮件日志；部分配置会给出不含凭据值的提示。修改配置只影响下一轮运行。旧的考试邮件入口保持停用，本功能不顺带启用考试通知。

日志按课堂分别保存在内存中，并跨重连累积，不会提交到公开仓库。附件只记录前述字段，不抓取整个控制台输出或主动采集 Cookie、JWT、图片地址字段、题库原始响应及模型推理过程；已知凭据原值会被替换，但这不能保证去除正文中的其他个人信息、链接或编码后的令牌。每个课堂最多保留 200 条处理记录，每个字段最多 2000 字符，超出部分会注明；同一题的多次实际处理仍会分别记录。等待结束后仍未完成的条目标为“仍在处理”，冻结附件后不再补录迟到结果。

尚未进入实际课堂（例如无课、SESSION 失效）时不会发送开始 / 结束邮件，可查看 Actions 的失败通知。Runner 被强制终止、任务被取消 / 超时、主机断电等情况可能来不及执行结束发送；SMTP 接受也不等于邮件一定已进入收件箱，请检查垃圾邮件和邮箱服务商投递限制。

验证范围：本地 Python 3.10 和 3.14 均通过 64 项单元 / 模拟回归测试，覆盖通知故障隔离、有界等待、重连去重及日志附件。SMTP、课堂接口和模型调用均为模拟；尚未验证真实收件箱投递、GitHub Runner 强制终止或真实课堂全链路。

### 选填：合工大课表自动同步

课表刷新工作流每天北京时间约 02:00 尝试执行，未同时配置两项教务 Secrets 时直接跳过。同一学期且筛选名单未变时跳过登录，新学期或名单变化时重新获取并提交精简课表。公开文件只保存学期编号、筛选课程名称和课程日期及起止时间；未排课的筛选课程仅保留名称用于比较名单。不会保存学号、密码、Cookie、教室、教师或原始响应，同学期的临时调课也不会自动反映。

仅合工大且能访问对应教务系统的用户需要配置 `HFUT_USERNAME`（学号）和 `HFUT_PASSWORD`（信息门户密码）两个 Secrets。它们只传给课表更新工作流；基础监听工作流只根据两项是否同时配置来选择课表模式，不接收教务凭据本身。凭据不会输出或写入课表文件。首次配置后，可在 Actions 页面手动运行一次 `Refresh HFUT course schedule` 来提前生成课表；即使不手动运行，定时工作流也会自动尝试。本地或服务器上若要使用已生成的课表，需自行设置环境变量 `COURSE_SCHEDULE_ENABLED=true`。若教务系统要求图片验证码，工作流会在同一登录会话中用英文 Tesseract OCR 识别，最多提交两次登录尝试；不会保存或打印验证码图片与识别结果。OCR 并不保证成功，失败后保留已有课表并退出，避免无限尝试。校内网络/VPN 限制或登录接口变更也可能导致失败，请查看该工作流的简短错误原因。

其他学校用户或不使用自动同步时，不必填写这两个 Secrets：更新工作流会跳过，Python 监听会按 `LISTEN_WINDOWS` 运行。但若启用了外部 Worker，它仍会读取 JSON，必须移除或替换继承课表并相应调整调度配置，避免误触发。另需注意，继承的课表及 `data/course_schedule.ics` 仍是本仓库的公开课程数据，不是你的课表；建议在自己的 fork 中移除或替换，不要订阅继承的日历。

### 选填：Android 课前提醒（ICSx⁵）

选用合工大课表自动同步后，课表更新工作流还会生成公开的 [`data/course_schedule.ics`](data/course_schedule.ics)，每次课程都带有课前 10 分钟提醒。它只包含已筛选课程的名称和时间，不包含学号、密码或教务会话。此提醒完全可选，不安装 ICSx⁵ 也不影响监听。手机同步后，提醒由 Android 本地日历发出，不依赖 GitHub Actions 在上课时准时运行。

需要提醒时，在 Android 手机上安装 ICSx⁵，并添加**自己仓库**的只读网络日历地址（设置一次即可，将 `<用户名>` 和 `<仓库名>` 替换为自己的）：

```text
https://raw.githubusercontent.com/<用户名>/<仓库名>/main/data/course_schedule.ics
```

同步后，在手机日历 App 中开启该日历的显示与通知权限，检查事件是否有“提前 10 分钟”提醒；部分日历 App 会忽略订阅文件中的提醒，需要在 App 内为该日历设置默认提醒。允许 ICSx⁵ 后台同步，并关闭针对它和日历 App 的严格省电限制。首次订阅或新学期更新可能需要等待同步，建议先核对一节近期课程的时间和提醒。即使 GitHub Actions 后续漏跑，已同步到手机的课程仍会按本地时间提醒。

## 方法2：本地 / 服务器部署

走本地方法的话建议

### 🌟 说明

可用系统定时任务或宝塔面板调用 `start.py`，自行监控任务、网络和登录状态。服务器调度更可控，但仍需维护；`SESSION` 过期不会由调度器自动恢复。

### 🚀 开始配置

1. 进入config.py，修改isLocal变量为True

2. 填写config.ini

3. 安装依赖
```bash
pip install -r requirements.txt
```

4. 配置config.py中
```python
filtered_courses=[
        # 默认为空 所有课题监听课程测试
        # 若填写课程名称 则只监听列表里的课，其余课仅签到,建议按自己需求添加
        "计算机组成原理","数据结构"
]
```

5. 在项目根目录配置调度并运行 `start.py`。使用已生成的课表时，设置环境变量 `COURSE_SCHEDULE_ENABLED=true`，保持本地 `data/course_schedule.json` 为最新学期，且上面的 `filtered_courses` 名称与课表一致。不使用课表时设置 `LISTEN_WINDOWS`，格式同前。监听时段内程序持续查课，时段外本地调用只做单次查课；没有外部定时任务或服务管理器时，程序不会自行等待下一节课。避免用定时任务不断启动重叠进程，设置任务互斥并检查运行日志。
```bash
python start.py
```


## 获取SESSIONID方式

访问 [长江雨课堂](https://changjiang.yuketang.cn/)，登录后按 F12，按下图查找 `sessionid`：
![图片1](src/screenShot/1.png)
![图片2](src/screenShot/2.png)
![图片3](src/screenShot/3.png)
![图片4](src/screenShot/4.png)

GitHub Actions 用户将值保存为仓库 Secret `SESSION`；本地 / 服务器使用 `isLocal=True` 时写入 `config.ini` 的 `SESSION` 字段。此文件包含登录凭据，填写真实值后不要提交或上传。不要使用不存在的 `config.txt`。

## [获取AI_KEY(AI 用于解题或辅助题库搜题规格化答案)](https://api.chatanywhere.org/v1/oauth/free/render)
## [获取ENNCY_KEY(言溪题库 用于题目为空时搜题)](https://tk.enncy.cn/)

本项目基于开源项目[Fuck-Yangtze-RainClassroom](https://github.com/Chiu-xaH/Fuck-Yangtze-RainClassroom)进行改进，感谢原作者的开源贡献！如果觉得本项目配置复杂，也可以尝试原项目的方法配置。

## 开发验证：离线自动化测试

推送代码或创建、更新 PR 后，`Offline tests` 会分别运行 Python 3.10、Python 3.14 和 Node.js 24 的测试。Python 3.10 与当前监听工作流一致；两个 Python 版本分别报告结果，不因其中一个失败而取消另一个。

测试流程只授予仓库读取权限，检出代码时不保留 Git 凭据，不引用仓库 Secrets。Python 使用虚构的测试 SESSION；课堂、SMTP、模型、Worker HTTP 和 KV 操作由现有测试替身处理。流程仅执行测试命令，不运行监听、课表更新或部署命令，也不会触发真实 Worker `/test`。

Python 仅安装 [`requirements-test.txt`](requirements-test.txt) 中的三个基础依赖，不安装整套生产依赖或加载 OCR 模型。该清单固定直接测试依赖版本，未锁定所有传递依赖，也不代表生产环境兼容性已验证；生产的 `requirements.txt` 保持独立。

在独立的本地测试环境中，可从仓库根目录执行：

```sh
python -m pip install -r requirements-test.txt
python -B -m unittest discover -s tests -v
node --test cloudflare/worker.test.mjs
```

任一测试失败都会使对应检查失败；若需要禁止合并失败的 PR，还需由仓库维护者将这些检查设为分支保护的必需检查。离线测试通过不等于真实课堂、邮件投递、模型依赖启动或线上 Worker 已验证。
