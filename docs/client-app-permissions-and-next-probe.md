# 客户端阶段 0：权限核对与下一轮测试

日期：2026-10-27；更新于 2026-10-30。类型：官方权限核对、已执行测试范围及后续计划；不代表完整客户端部署验收。

## 1. 当前建议

**GitHub App 的设备授权、选定仓库限制和无 Client Secret 立即刷新已在本机实测通过**。target 唯一一次空任务成功，control 触发请求返回 403 且无运行，脱敏结果见[执行证据](verification/client-s0-github-app-scheduler.json)。

调度身份继续只使用 `Actions: write` 和基础 `Metadata: read`。后续独立 Worker 内的立即刷新与空任务触发也已真实通过，详见[云端证据](verification/client-s0-worker-runtime.json)。2026-10-28 又通过独立管理 App 完成配置、工作流、Secrets 及 Actions 开关的真实验证，并确认任务实际读到 Secret；详见[管理实测与收尾](verification/client-s0-github-manager-runtime.json)。同日 Cloudflare 本人账号发现与自动资源部署／绑定读取也已通过；调度端不默认保存一份完整管理凭据。

最初的文档核对后，用户明确批准并完成了下文的私有 GitHub App 与两个空测试仓库验证；该本机轮撤销的独立核验边界保留。随后另行批准的一个独立 Worker 测试及收尾也已完成，成功轮撤销已实测 401、测试公网入口 404。两轮均未操作现有业务仓库、生产 Worker 或真实课堂。

## 2. GitHub 的权限边界

### 已核对的接口要求

下表来自 2026-10-27 获取的 GitHub REST 文档；细分权限适用于 GitHub App 等细粒度令牌。传统 OAuth App 使用另一套 scope，二者不能混用。

| 软件操作 | 主要接口 | GitHub App 的权限要求 | 传统 OAuth App 的文档要求 |
| --- | --- | --- | --- |
| 创建 Fork | `POST /repos/{owner}/{repo}/forks` | `Contents: read`，加 `Administration: write` 或 `Repository creation: write`；还有下述安装范围限制 | 另行实测公开仓库 Fork；不能据此认定全部部署只需 `public_repo` |
| 更新普通代码或配置 | `PUT /repos/{owner}/{repo}/contents/{path}` | `Contents: write` | 接口文档列出 `repo` |
| 新建或修改工作流文件 | 同上，路径为 `.github/workflows/…` | `Contents: write` 和 `Workflows: write` | `repo` 加 `workflow` |
| 写入仓库 Secret | `PUT /repos/{owner}/{repo}/actions/secrets/{secret_name}` | `Secrets: write`；上传前使用仓库公钥加密 | `repo` |
| 触发、启用、禁用工作流 | `/repos/{owner}/{repo}/actions/workflows/{workflow_id}/…` | `Actions: write` | `repo` |
| 改仓库级 Actions 开关或允许策略 | `PUT /repos/{owner}/{repo}/actions/permissions` | `Administration: write` | `repo` |

`Metadata: read` 是 GitHub App 的基础只读权限。启用某个工作流与修改仓库级 Actions 策略是两个接口，不能把前者的权限当成后者的权限。

`Actions: write` 也允许管理相关仓库的工作流运行等 Actions 操作，不是平台提供的“只能 dispatch”权限。本轮用它验证触发能力，但不会把测试程序只调用 dispatch 描述为令牌只能调用 dispatch。

### 为什么不直接给现有 OAuth App 加权限

GitHub 官方说明：传统 OAuth App 的 `repo` 涵盖用户可访问的公开和私有仓库，无法像 GitHub App 安装时那样只选择本项目仓库。软件里固定仓库名只能限制正常程序的行为，不能缩小令牌本身的权限。

`public_repo` 仍覆盖用户可访问的公开仓库；它也不是“仅授权一个公开仓库”。Secrets、dispatch、工作流更新等接口当前文档分别列出了 `repo`、`workflow`，本次未实测更小 scope 是否适用，不承诺 `public_repo` 足够覆盖整个部署流程。

### GitHub App 的设备授权值得优先验证

GitHub App 可以采用设备授权，用户通过官方页面完成确认。官方刷新文档明确说明：如果用户访问令牌来自设备授权，刷新时可以省略 Client Secret。用户令牌受用户自身权限、App 权限和安装仓库范围共同限制。

因此，可先验证一个由项目方注册的 GitHub App，让用户只选择自己的项目仓库；设备授权产生的刷新令牌由用户自己的 Worker 保存并续期。这条候选路线无需把项目方的 App 私钥或 Client Secret 放入客户端或用户的 Worker，也不以公共签发服务为前提。

这条路线的本机最小验证和 Worker 内单次立即刷新、空任务触发均已完成，长期运行及轮换后的持久保存仍待验证。它使用的是 **GitHub App 用户访问令牌**，不是一小时到期的安装令牌。独立证据中分别保留了本机 App、云端 App 和之前 OAuth App 的结果。

GitHub App 的 `scope` 不能用于任意裁剪仓库权限，官方仅支持通过 `offline_access` 控制过期行为。因此，后续应分别考虑调度端的最小 `Actions: write` 身份和客户端的部署管理身份；不能声称同一个 App 的管理令牌已自动降权为只允许调度。

### 自动 Fork 仍有独立约束

官方 Fork 接口说明：GitHub App 需要在目标账号安装并具有全部仓库访问范围，同时在来源账号具有来源仓库访问权限。不能把“选定单个仓库”的安装方式直接当作完整自动 Fork 方案。

可继续验证的首版路径是：新用户在 GitHub 官方 Fork 页面完成一次确认，再返回软件选择并管理该仓库；已有 Fork 的用户直接接管。能通过接口完成的后续配置留在软件中。若坚持全自动 Fork，需要单独选择和验证引导授权方式，不能为此默认扩大长期授权到全部仓库，也不把复制源码新建仓库称为 Fork。

本次不注册每用户一个 App，不生成 PEM 私钥。每用户 App 的 Manifest 路线作为备选保留，不是当前选定的实现。

## 3. Cloudflare 的部署权限

已查询 Cloudflare 官方 `api-schemas`，下表是接口的 `x-api-token-group` 权限名称，不能直接当作 OAuth scope ID。本人账号测试使用的五项 OAuth ID 已另外从官方详情核对，实际成功范围见本节末；Cron 尚未实测。

| 需要的操作 | 官方接口 | 文档列出的适用权限 |
| --- | --- | --- |
| 上传 Worker、配置绑定 | `PUT /accounts/{account_id}/workers/scripts/{script_name}` | `Workers Scripts Write`；接口也列出部分 Worker 角色权限，后续核对可用范围 |
| 写 Worker Secret、配置 Cron | 上述脚本下的 `/secrets`、`/schedules` | `Workers Scripts Write` 等适用权限 |
| 读取已有 workers.dev 子域、启用脚本访问 | `/workers/subdomain`、脚本下的 `/subdomain` | 读取支持 `Workers Scripts Read/Write`；启用支持 `Workers Scripts Write` 等权限 |
| 创建 KV namespace | `POST /accounts/{account_id}/storage/kv/namespaces` | `Workers KV Storage Write` |
| 创建 D1、执行测试写入 | `POST /accounts/{account_id}/d1/database`、数据库下的 `/query` | 创建需要 `D1 Write`；测试写入按 `D1 Write` 准备 |

下一轮资源测试不需要 DNS 编辑、域名管理、账单权限或更改套餐。公开 OAuth 客户端的域名验证是另一个操作，不与业务部署权限捆绑。

账号发现已通过 `memberships.read` 和 Memberships 接口实测；先前的 `User Details Read` 只读身份测试未覆盖账号列表。只在客户端正常工作期间需要 Cloudflare 管理授权；现有 Worker 已部署后的定时执行不依赖客户端持续持有 Cloudflare 管理令牌。Cloudflare 刷新未通过，不影响前面已验证的授权结果，也不等同于 GitHub 离线调度授权可忽略。

资源名白名单只能约束测试程序；不能将其描述为 Cloudflare 平台已限制令牌只访问一个 Worker、KV 或 D1。具体可限制到账号还是单个资源，需单独检查实际授权能力。

2026-10-28 已按明确授权创建独立私有管理客户端。首轮五项中的 Workers Editor（`workers-scripts.edit`）上传返回 403；主人单独批准仅替换为 Workers Admin（`workers-scripts.admin`）。另外四项保持 `d1.write`、`workers-kv-storage.write`、`memberships.read`、`user-details.read`。第二轮进入脚本校验，返回 400／10021；修正 ES module 上传类型后，第三轮自动部署、Secret 和入口配置、Worker 实际 KV／D1 读取均通过。Secret、KV、D1 已删除，空 Worker 关闭并解除绑定，令牌撤销及随后 403、公开入口 404 均已核验。20 项本地检查和[三轮真实结果](client-app-cloudflare-manager-probe-plan.md)分别保存；不补作首轮 403 精确原因的断言，也不覆盖 Cron 或公开跨账号授权。

## 4. 已执行的最小测试：只验证 GitHub 调度身份

### 用户已批准的测试范围

| 项目 | 明确范围 |
| --- | --- |
| 私有测试 GitHub App | 名称拟为 `Rain S0 Scheduler 20261027`；仅本人测试，启用 Device Flow 和过期用户令牌，关闭 Webhook，不生成 Client Secret 或 PEM 私钥 |
| App 权限 | 仅 `Actions: write` 和基础 `Metadata: read`；不申请 Contents、Workflows、Secrets、Administration 或组织权限 |
| 目标仓库 | `frewily/rain-client-s0-target-20261027`，新增公开测试仓库，仅含说明和空测试工作流 |
| 对照仓库 | `frewily/rain-client-s0-control-20261027`，新增公开测试仓库，放置同一份空工作流；不加入 App 安装范围 |
| 安装范围 | 只选择目标测试仓库，不选择全部仓库，不选择现有业务仓库 |
| 工作流内容 | 使用本目录的 [空测试工作流](verification/fixtures/s0-dispatch-probe.yml)，只有 `workflow_dispatch`，不 checkout、不读取 Secret、不请求外部业务接口，没有 Cron、push 或 pull_request 触发 |
| 测试运行 | 对目标和对照仓库各最多提交一次 dispatch；若对照请求意外成功，也只运行同一份空工作流，并将权限隔离判为失败 |
| 凭据 | 新设备授权及刷新令牌只留临时进程内存，不放入现有 Worker 或仓库；仅保存脱敏状态、权限及 HTTP 结果 |
| 清理 | 测试后撤销测试授权、停止本地程序，测试仓库和 App 注册保留；不默认删除资源，不提交或推送本业务仓库 |

创建仓库及写入这两个测试仓库的工作流，是验证准备动作，使用 GitHub 官方页面或已有授权工具完成；它们不证明新 App 具有创建仓库或写代码的能力。新 App 的测试权限刻意不含这些能力。

### 测试顺序与判定

1. 同名资源存在则停止创建并核对归属，不覆盖。确认账号为 `frewily`，否则停止使用预设目标。
2. 在两个新仓库各放置空工作流，核对事件仅 `workflow_dispatch`。若平台需要账号或 Actions 开通确认，由用户在官方界面完成。
3. 在官方页面注册、安装上述私有 App，只授权目标测试仓库。核对实际安装范围和权限。
4. 设备授权只使用该 App 的公开 Client ID；不发送 Client Secret。检查身份，不保存原始个人信息。
5. 在独立程序中立即刷新，核对新令牌可用、身份一致、旧访问令牌失效；这是立即刷新测试，不冒充等待八小时后的验证。
6. 新令牌向目标仓库提交一次 dispatch。本次明确使用 `2026-03-10` API 版本，成功返回 200，并提供运行 ID 和 URL；不能套用旧版本的 204 判断。继续观察相应运行是否实际开始并成功完成，分别记录接口接受和 Runner 结果。
7. 向未安装 App 的对照仓库提交同一请求，预期被拒绝。不能用读取公开仓库信息的成功或失败判断隔离，因为公开信息可能不需要授权。
8. 撤销测试授权、清除临时持有值并停止服务，记录实际清理结果；未独立核实的撤销结果不写成完成。

第 4 节保留的是先前的本机轮范围，当时没有部署 Cloudflare Worker。后续另行获准执行的[独立 Worker 测试](client-app-worker-probe-plan.md)已通过并完成收尾，仍未配置 Cron、接入真实课堂或在业务仓库写入 Secrets。

## 5. 后续顺序

1. 已完成：上述 GitHub App 调度身份的本机功能验证；撤销失效未独立复核的边界保留。
2. 已完成：独立测试 Worker 内立即刷新与空工作流 dispatch；本轮新增一次成功运行，无 Cron，成功轮撤销及公网入口关闭已核验。长期调度不在此结果内。
3. 已完成：客户端管理身份在选定空仓库中的配置、工作流、Secrets、Actions 设置及真实任务读取验证；自动 Fork、公开跨账号安装及已有文件升级冲突仍待验证。
4. 已完成本人账号范围：Cloudflare 官方 OAuth 准确 scope、账号发现、独立 Worker/KV/D1 自动部署、Secret 配置及真实绑定读取；清理与撤销通过。公开跨账号授权、Cron 另行验证。
5. 安卓登录初版已在 `apps/client` 实现，静态分析、26 项合成行为测试和 ARM64 开发 APK 核验通过；主人已报告四个交付步骤通过，包括实际官方登录、重开恢复和本机退出。具体微信跳转路径、断网恢复未单独报告，详见[登录验收表](client-app-login-acceptance.md)。窄屏显示调整按主人要求随下个功能版本查看；后续优先 GitHub 绑定和仓库识别，再推进 Cloudflare 与云端配置。Mac、长期调度与正式发布仍分别验收。未列 SDK／插件仍先给出范围。
6. 安卓 GitHub 绑定已通过本地检查和主人真机反馈：累计 66 项测试、合成预览及 0.2.0 开发包核验通过；2026-10-30 主人反馈官方授权、账号／原测试仓库识别与选择、重开恢复四步均通过。未独立读取真实令牌或观察设备，也不将其算作真实凭据更新通过。下一段是 [Cloudflare 账号绑定与手机返回](client-app-cloudflare-binding.md)，再进入部署配置。

这只是阶段 0 剩余工作的顺序，不表示这些步骤已经获准执行，也不将其算作客户端产品开发完成。

2026-10-28 已按明确批准的[独立 GitHub 管理验证方案](client-app-github-manager-probe-plan.md)完成第 3 步中的管理能力验证：单独管理 App 五组写权限仅安装 target，33 项本地检查及实际成功任务分别记录；测试文件与 Secret 已删除、策略恢复、成功轮令牌 401、进程退出、专用临时环境删除。独立只读回查确认文件树与原基线相同，target 累计 3 次运行且 control 为 0。该轮没有扩大调度 App 权限或操作 Cloudflare；后续第 4 步另经明确批准完成。

## 6. 官方依据

- [GitHub OAuth scope 范围](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)。
- [GitHub App 与 OAuth App 的区别](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps)。
- [GitHub App 用户令牌与设备授权](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app)。
- [GitHub App 刷新用户令牌](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens)。
- [GitHub Fork 接口与安装范围要求](https://docs.github.com/en/rest/repos/forks#create-a-fork)。
- [GitHub Contents 和工作流文件权限](https://docs.github.com/en/rest/repos/contents#create-or-update-file-contents)。
- [GitHub 仓库 Secrets 权限](https://docs.github.com/en/rest/actions/secrets#create-or-update-a-repository-secret)。
- [GitHub dispatch 与工作流启用权限](https://docs.github.com/en/rest/actions/workflows)。
- [GitHub 仓库级 Actions 权限](https://docs.github.com/en/rest/actions/permissions#set-github-actions-permissions-for-a-repository)。
- [GitHub App Manifest 备选路线](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest)。
- [Cloudflare 官方 API schema](https://github.com/cloudflare/api-schemas/blob/main/openapi.json)。
- [Cloudflare OAuth 客户端与 scope](https://developers.cloudflare.com/fundamentals/oauth/create-an-oauth-client/)。

公开文档的脱敏提取与 SHA-256 见 [权限核对证据](verification/client-s0-permission-research.json)，这是测试执行前的文档快照；执行结果另见 [GitHub App 实测摘要](verification/client-s0-github-app-scheduler.json)，不要将两个证据等级混淆。
