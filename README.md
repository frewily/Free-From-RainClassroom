# 长江雨课堂定时签到+听课答题
**🌟 雨课堂、荷花、黄河等应该就HOST和API不同吧，可以自己试试，改下API应该就行?**

## 方法1：Cloudflare Workers + GitHub Actions（推荐的云端调度方式）

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

**两个工作流的触发方式不同：**

| 工作流 | 当前触发器 | 职责 |
| --- | --- | --- |
| [python-app.yml](.github/workflows/python-app.yml) | 仅 `workflow_dispatch`；已移除 GitHub `schedule` | 监听执行，可由 Worker API 或 Actions 页面手动启动 |
| [course-schedule.yml](.github/workflows/course-schedule.yml) | GitHub `schedule: 0 18 * * *` 和 `workflow_dispatch` | 可选的合工大课表刷新及 ICS 日历生成 |

Cloudflare 每 5 分钟检查一次是否需要**启动任务**；`start.py` 在监听时段内每约 5 分钟**检查课堂**，这是两个独立的周期。进入时段后运行到该时段结束，同一轮不会重复处理同一课堂。当前监听工作流所有调用都属于 `workflow_dispatch`，时段外也会安装依赖并执行一次查课；时段判断格式无效等错误仍会导致任务失败。没有配置外部调度器时，该监听工作流不会自行定时启动。

监听工作流采用同一 `concurrency` 组、`cancel-in-progress: false`：同一时间最多执行一轮，等待中的任务可能被更新的任务替换，不能依赖排队任务接替异常退出的监听。环境初始化和依赖安装约需 75 秒（经验值，非承诺），再叠加排队时间，不能将 dispatch 时间当作实际开始查课时间。

签到记录写入运行环境的 `log.json`，不再提交到公开仓库。Actions 环境是临时的，结束后仓库不保留这些记录；本地可在本机查看。旧提交中的历史记录不会因此消失。

### 部署前：课表与监听配置必须一致

先完成下方 GitHub Actions 基础配置和可选的合工大同步，再配置 Worker。Worker 读取的是公开 JSON，不会读取 GitHub Secrets，也不会根据 `LISTEN_WINDOWS` 推导课表。

- [`data/course_schedule.json`](data/course_schedule.json) 顶层包含 `semester`、`selected_courses`、`classes`；每条 `classes` 仅有 `course`、`date`、`start`、`end`。日期为 `YYYY-MM-DD`，时间为北京时间 `HH:MM`。JSON 已按课程筛选，Worker 按实际 `classes` 调度；仅出现在 `selected_courses` 中但没有实际排课的课程不会触发。
- Actions 仅当 `HFUT_USERNAME` 和 `HFUT_PASSWORD` 两项 Secrets 均已配置时，才自动设置 `COURSE_SCHEDULE_ENABLED=true`。此时 Python 优先读取课表，还会核对当前学期，并用 `FILTERED_COURSES` 再筛选一次。文件存在但学期过旧时不会退回固定时段；文件缺失时才使用 `LISTEN_WINDOWS`。
- 不配置教务 Secrets 时，Actions 按 `LISTEN_WINDOWS` 运行，即使仓库有 JSON 也不会自动启用课表模式。其他学校可以自行维护同格式 JSON 供 Worker 调度，但仍须配置对应的 `LISTEN_WINDOWS` 才能让当前 Actions 在窗口内持续监听；单独添加 JSON 不够。后文的服务器环境可显式设置 `COURSE_SCHEDULE_ENABLED=true`。
- 修改 `FILTERED_COURSES` 后先运行课表刷新工作流，核对提交后的 JSON，再用 Worker 预览，避免两端依据不同数据。不要使用从别人的 fork 继承的课表调度自己的账号。

### Cloudflare 控制台部署与配置

**部署来源说明：** 当前 Worker 通过 Cloudflare 控制台部署，本仓库没有 Worker 源码、Wrangler 配置或自动部署流程。以下记录现有部署的行为与配置；从零复现还需要取得现有 Worker 源码并核对接口约定。不能只创建空 Worker、填写变量就认为调度已实现。`/preview` 的日期字段、密钥所在请求头或请求体字段及返回结构未在仓库定义，应以实际部署源码或脱敏联调记录为准，这里不编造接口格式。

1. **准备 GitHub。** 在自己的仓库启用 Actions，确认 `main` 上存在上述工作流，完成基础 Secrets 配置并核对公开课表。Fork 用户须把 Worker 中仓库、Raw URL、API 路径和分支一起改成自己的，避免触发本仓库。
2. **创建最小权限 PAT。** 在 GitHub Settings → Developer settings → Personal access tokens → Fine-grained tokens 创建令牌，Resource owner 选择目标仓库所有者，Repository access 仅选择目标仓库，Repository permissions 仅额外授予 **Actions: Read and write**（Metadata 为必需只读权限）。为令牌设置有效期并安排轮换；组织仓库还需检查审批策略。此令牌无需为了 dispatch 获取 Contents 写权限。课表刷新工作流自身的 `contents: write` 是另一个用途。
3. **创建 Worker。** 在 Cloudflare Workers & Pages 创建 Worker，将现有调度源码导入控制台编辑器并部署。核对它包含 `scheduled()`、课表读取和北京时间转换、15 分钟窗口判断、同一开课时间合并、KV 检查、dispatch、接口鉴权，以及演练开关逻辑。课表 URL 为 `https://raw.githubusercontent.com/frewily/Fuck-Yangtze-RainClassroom/main/data/course_schedule.json`；公开读取不需要 PAT，不应把 PAT 发给 Raw 域名。
4. **创建并绑定 KV。** 在 Cloudflare 的 KV 管理页创建 Namespace，在 Worker Settings 的 Bindings 中新增 KV Namespace binding，变量名必须为 `TRIGGER_KV`，选择刚创建的 Namespace。绑定到实际部署环境；仅创建 Namespace 而未绑定不可用。
5. **配置 Secrets 和变量。** 在 Worker Settings 的 Variables and Secrets 中添加下表项目，保存后部署生效。先使用演练模式检查课表匹配和日志；确认源码确实将开关关闭值解释为不自动 dispatch，再开启正式模式。控制台常以字符串保存变量，须按源码要求填写和解析，不能把字符串 `"false"` 当成布尔真值。
6. **添加 Cron Trigger。** 在 Worker 的 Triggers / Cron Triggers 配置 `*/5 * * * *`，保存并确认触发器关联当前 Worker。Cron 调用的是 `scheduled()`，不依赖浏览器访问 HTTP 路由；配置传播可能需要等待，以日志确认生效。
7. **按下文验证。** 先做只读预览，再做受保护的真实测试，最后观察真实课程窗口。`/test` 是真实触发接口，演练时也不要误调用；其是否受 `AUTO_DISPATCH` 限制须核对源码，不能将此开关视为 HTTP 接口的统一禁用开关。

| 名称 | Cloudflare 配置类型 | 用途 |
| --- | --- | --- |
| `GITHUB_TOKEN` | Secret | 上一步创建的 fine-grained PAT，用于 GitHub API dispatch；不是 Actions 自动注入的同名令牌 |
| `TEST_TRIGGER_KEY` | Secret | 保护 `POST /preview` 和 `POST /test`，使用独立高强度随机值 |
| `TRIGGER_KV` | KV Namespace binding | 保存 GitHub 已接受的课程触发请求记录 |
| `AUTO_DISPATCH` | 普通变量 / 源码约定的开关 | 区分 Cron 演练与正式自动提交；当前部署据用户确认已开启 |

不要把真实 PAT、测试密钥、`SESSION`、教务密码放进 README、源码、URL 查询参数、公开日志或截图。Cloudflare 只需调度令牌和测试密钥，雨课堂 `SESSION` 等业务凭据仍留在 GitHub Actions Secrets。日志只记录脱敏的匹配结果、KV 状态及 HTTP 状态码；令牌泄露应撤销并重新配置，过期后也需更新。

### Cron 时区、触发窗口与去重语义

Cloudflare Cron 使用 **UTC**，课表匹配使用**北京时间 UTC+8**，日期也必须按北京时间计算。`*/5 * * * *` 在两种时区都表现为每 5 分钟一次；若设置固定时间，北京时间 08:00 对应 UTC 当天 00:00，北京时间 02:00 对应 UTC 前一天 18:00。因此课表刷新工作流的 `0 18 * * *` 表示北京时间次日 02:00，并非北京时间 18:00。

现有 Worker 在课程开始后的 15 分钟触发窗口内允许补触发；例如 08:00 开始的课程，08:05、08:10 仍可匹配，具体 08:15 端点是否包含以部署源码和 `/preview` 边界测试为准，不应依赖最后一个边界时刻。超过窗口不会补触发，连续调度失败或延迟可能错过整个窗口。

同一天相同开课时间合并为一次 dispatch，例如 KV 键 `rainclassroom:2026-10-20:08:00`，不按课程名称分别启动。GitHub 接受请求后保存记录，TTL 为 14 天（1,209,600 秒）。该记录表示**已提交且 GitHub 接受触发请求**，并不表示 Runner 已启动或签到答题成功；后续任务失败也不能指望同一记录自动重试。

KV 具有最终一致性，先读再调用 API 再写的过程不具备原子锁语义。并发读取、跨位置可见性延迟、API 接受后 KV 写入失败都可能造成重复；网络超时也可能让提交结果不明确。Actions 的并发组限制执行数量，但不是按课程键的严格去重。需要人工补跑时先检查已有 run，再决定是否手动触发，避免盲目删除 KV 记录反复重放。

### GitHub API 与手动接口

Worker 向以下 GitHub REST API 发送 POST（Fork 应替换所有者、仓库和分支）：

```text
https://api.github.com/repos/frewily/Fuck-Yangtze-RainClassroom/actions/workflows/python-app.yml/dispatches
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

- **`POST /preview`：** 通过 `TEST_TRIGGER_KEY` 鉴权，输入模拟北京时间，检查日期、开课时间和触发窗口匹配；不实际 dispatch，也不写入课程触发记录。请求字段与鉴权位置须查阅现有 Worker 源码。测试课前、窗口内、窗口外、同一天同一开课时间多条记录以及北京时间跨日边界。
- **`POST /test`：** 通过同一测试密钥鉴权，发起真实 `workflow_dispatch`。不要把打开浏览器 GET 页面当作测试成功，也不要假定它会绕过或修改课程 KV 记录，具体行为以部署源码为准。它可以在无课时启动 Actions，而 Python 此时可能只做单次查课。

### 验证状态与验收步骤

截至 2026-10-19，仓库触发器与 Python 行为已按最新代码核对；下表中的 Cloudflare 结果来自用户联调反馈，未由本仓库的自动测试覆盖。

| 项目 | 当前证据与边界 |
| --- | --- |
| Cron `*/5 * * * *` 执行 | 已观察 Worker Cron 运行，不等于真实课程已自动启动 Actions |
| 公共 JSON GET、北京时间匹配、`/preview` | 用户已验证成功 |
| KV 读写 | 用户已验证成功，不等于并发严格去重 |
| 受密钥保护的 `POST /test` | 返回 200，GitHub dispatch 实际启动并执行成功 |
| `AUTO_DISPATCH` 正式开关 | 用户表示 `true` 已部署，仍需真实课程窗口验收 |
| 真实课程窗口的 Cron → Actions → 持续监听 | 待实测，不能用手动接口结果替代 |
| 并发去重、长期稳定性、实际签到答题结果 | 尚未充分验证，需单独观察业务日志 |

建议按以下层次验收，并分别记录时间与结果：

1. 检查 `main` 的 JSON 日期、课程名称、起止时间、当前学期及 Actions 的课程筛选配置。以实际 `classes` 为准，不根据课程名称元数据猜测哪天有课。
2. 使用现有接口约定调用受保护的 `POST /preview`，确认模拟时间匹配正确，Actions 没有新 run，课程 KV 没有新增记录。
3. 主动调用一次受保护的 `POST /test`，检查 Worker 状态码及 GitHub Actions 新 run 的事件类型、分支、开始时间和步骤结果。无课时的“手动单次检查课程 / 无课”只能证明执行链路可达。
4. 正式课前确认开关与 Cron 配置。课时到来后记录 Worker Cron 时间、匹配结果、API 接收结果及 KV 键，再核对 Actions 创建、Runner 开始、依赖安装结束和进入监听窗口的时间。下一次 Cron 检查同一键是否跳过，并核对该时段是否出现重复 run。
5. 最后查实际课堂日志中的签到、监听和答题结果；只显示任务绿色或 KV 有键不算业务验收。多次观察后才能评估稳定性，一次正常跳过也不足以证明无并发竞态。

### 排错

| 现象 | 检查方向 |
| --- | --- |
| Cron 没有日志 | 确认已部署、Trigger 存在且属于正确环境，检查配置传播和 Worker 运行错误；HTTP 测试不能代替 `scheduled()` 验证 |
| 有 Cron 日志但不触发 | 核对 `AUTO_DISPATCH` 解析、Raw URL / main、HTTP 与 JSON 格式、北京时间日期、15 分钟窗口和现有 KV 键；检查课表是否仍是旧学期或未更新筛选名单 |
| `/preview` 或 `/test` 拒绝请求 | 确认使用 POST、已部署的测试密钥、源码要求的请求字段及鉴权位置；不要在日志中打印密钥 |
| GitHub API 401 / 403 / 404 / 422 | 检查 PAT 是否过期、授权仓库及 Actions 写权限、组织审批或限流、路径与工作流文件名、Actions 是否启用，以及 `ref: main` 是否存在；按脱敏响应判断具体原因 |
| Worker 报成功但没看到执行 | 核对 API 真正接受的状态与目标仓库，查看 Actions 排队、并发组、运行记录及取消状态；KV 记录不保证后续成功，也不提供自动业务重试 |
| 重复启动 | 检查是否额外手动触发、存在多个 Worker / Cron，以及 KV 最终一致性、先读后写竞态或写入失败；核对键是否按同一天相同开课时间合并 |
| 只单次查课，未持续监听 | 核对实际启动时是否仍在窗口内、两项教务 Secrets、`FILTERED_COURSES`、课表学期及 `LISTEN_WINDOWS`；dispatch 不会强制 Python 忽略监听窗口 |
| 雨课堂 401 / 403 或提示登录失效 | 更新 Actions 的 `SESSION` 后重试；也可能是接口或服务变化。调度器不能修复登录状态；服务器用户更新本地凭据 |
| 临时调课未体现 | 同一学期、相同筛选名单会跳过教务登录，即使手动运行刷新也不会强制重新抓取；核对教务实际安排并自行更新课表，不能把每日工作流当作每日全量同步 |

GitHub 失败通知需在账号通知设置中启用并自行确认；当前监听 YAML 的邮件环境变量处于注释状态，不能认为项目内邮件提醒已配置。

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
