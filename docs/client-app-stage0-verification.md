# 客户端阶段 0：首轮验证记录

日期：2026-10-26；进展更新于 2026-11-01。基线：`e2a16afbc2f58c0ab524491af0e5a738cf087b92`。

本记录区分真实账号验证、公开服务与官方文档检查，以及尚未执行的验证。现有课堂代码、生产 Worker、Secrets 和 Cron 未修改，未启动课堂任务。

## 1. 当前结果

| 项目 | 证据等级 | 结论 |
| --- | --- | --- |
| Mac 原生窗口加载官方雨课堂登录页 | 本机实际运行 | 通过；二维码能显示、刷新，按钮可响应 |
| 新窗口独立登录并取得会话 | 用户正常扫码，程序实际检查 | 通过；取得 Secure、HttpOnly 的 `sessionid` |
| 会话供独立 HTTP 客户端使用 | 真实账号，只读接口 | 通过；仅携带该会话请求个人信息接口，HTTP 200 且有有效用户记录 |
| 临时会话清理 | 本机实际执行 | 已清理并关闭临时程序；只保存无凭据的结果摘要 |
| Flutter 的 Mac 登录插件 | 未执行 | 原生能力通过不等于 Flutter 工程集成通过 |
| Flutter／Android 工具链及测试 APK | 本机安装、分析、测试和实际构建 | 通过；Flutter 3.47.8／Dart 3.13.7、固定 Android 组件已安装到通用目录，doctor 安卓工具链通过，合成界面静态分析及 1 项测试通过，debug APK 构建、包名和签名核验通过 |
| Android 测试包基础界面运行 | 用户报告 | 主人反馈能打开、点击后计数变化、退出重开后计数归零；尚未独立连接设备或核对设备信息，人工反馈与自动测试分别记录 |
| Android 真实登录、重开恢复和本机退出 | 用户报告通过 | 主人报告四个交付步骤全通过；未独立读取设备、会话或具体微信跳转路径，断网恢复未单独报告 |
| 安卓登录客户端代码与构建 | 实现、合成测试、匿名接口对照和 APK 核验 | `apps/client` 初版已实现；静态分析、26 项行为测试、合成预览、ARM64 Release 开发包及 16KB 对齐通过。窄屏显示调整已通过离线复现和原有测试，按主人要求留待下个功能版本查看 |
| 安卓 GitHub 客户端绑定 | 实现、合成测试、APK 核验及用户反馈 | 0.2.0 的静态分析、累计 66 项测试及开发包核验通过；2026-10-30 主人反馈手机官方授权、账号／仓库识别和选择、重开恢复四步均通过。未独立观察手机或验证真实凭据更新；本轮未作远端写入 |
| 安卓 Cloudflare 官方授权返回 | 真机官方授权、用户反馈及 USB 固定状态观察 | 原版后台返回曾超时；0.3.1 保活未完全解决，原生回环接收接入后真实授权通过，观察到账号已连接；未读取凭据，未证明所有安卓厂商兼容 |
| 安卓测试部署整段功能 | 真机应用操作、独立 GitHub job／步骤及公开入口查询 | 0.3.4、113 项本地测试及构建通过；应用部署合成 Worker／单份工作流，任务 41286937681 首个 attempt 实际成功，手机显示同一结果，入口关闭且独立 HTTP 404。首轮 41285795738 为真实失败并已清理，未混作成功；手机直连仍未通过。详见[本轮实测](client-app-android-callback-fix.md) |
| GitHub 设备授权与刷新 | 真实账号，独立验证进程 | 通过；仅获 `read:user`，不发送 Client Secret 的刷新成功，新令牌可用、旧令牌返回 401 |
| GitHub App 调度身份与仓库隔离 | 真实账号、真实空工作流 | 通过；仅授权 target，本机轮刷新及唯一一次空任务成功，control 的触发请求返回 403 且无运行 |
| GitHub App 测试清理 | 用户报告与本机状态 | 主人已执行撤销；原令牌在限额暂停期间被程序按时丢弃，未独立复核撤销失效；两个临时服务已停止 |
| 独立 Worker 内刷新与触发 | 真实 Cloudflare Worker、真实空任务 | 通过；本地未刷新，Worker 刷新与 dispatch 均为 200，旧令牌 401；本轮新增一次成功运行 |
| Worker 成功轮清理 | 自动令牌核验、公开入口只读检查、本机进程状态 | 通过；成功轮新令牌撤销后 401，测试入口 404；本地服务停止，资源保留 |
| GitHub App 管理身份 | 真实指定空仓库、真实测试任务 | 通过；五组管理写权限下，配置／工作流创建与回读、Secret 加密写入、Actions 关闭及恢复均成功；唯一一次新增任务实际读到 Secret 并成功完成 |
| GitHub 管理验证收尾 | App 自身回读、撤销检查、独立只读回查 | 通过；测试文件与 Secret 删除，策略恢复，成功轮令牌 401，进程退出、临时环境删除；文件树与原基线一致，target 累计 3 次运行、control 仍为 0 |
| Cloudflare 私有客户端 PKCE 授权 | 真实账号，只读接口 | 通过；无 Client Secret 的令牌交换及用户信息请求均为 200，实际权限仅 `user-details.read` |
| Cloudflare 刷新与撤销 | 真实授权结果与撤销后请求 | 此次未返回刷新令牌，刷新未验证；访问令牌撤销返回 200，撤销后同一接口返回 403 |
| Cloudflare 管理身份首轮 | 真实 PKCE 授权与合成存储 | 部分通过；Memberships 账号发现、KV／D1 创建和读写通过，Worker 上传 403，整体部署及绑定读取未通过 |
| Cloudflare 管理首轮收尾 | API 回读与令牌失效检查 | 已删除首轮 KV／D1，Worker 未创建；撤销 200、随后个人信息接口 403，进程和服务退出 |
| Cloudflare 管理身份成功轮 | 真实 PKCE 授权、自动部署及公网请求 | 通过；经单独批准使用 Workers Admin，修正 module 上传类型后，Worker／KV／D1／Secret 配置成功，Worker 实际读取两项存储的摘要均匹配 |
| Cloudflare 管理成功轮收尾 | API 回读、撤销及独立公开入口检查 | 通过；Secret、KV、D1 删除，Worker 入口关闭且绑定为空，保留空 Worker；撤销 200、随后个人信息接口 403，公开入口 404，本地服务退出 |
| Mac 发布签名 | 本机身份列表检查 | 当前本机没有可用签名身份；不据此判断用户是否拥有开发者账号 |

因此，阶段 0 仍未全部完成。已经实测通过的是 Mac 原生登录与会话复用、GitHub 低权限 OAuth 设备授权、GitHub App 指定仓库调度与管理身份、独立 Worker 内立即刷新与空任务触发，以及 Cloudflare 私有 PKCE 只读访问和本人账号中的自动资源部署／绑定读取。安卓登录、GitHub 连接的用户验收，以及本轮手机 Cloudflare 授权到测试部署／实际空任务结果的闭环也已通过。Mac Flutter 集成、自动 Fork、公开跨账号授权、云端轮换令牌持久化和长期调度仍待验证；Cloudflare OAuth 自身的刷新、Cron 配置、真实课表与课堂接入也未在本轮完成。

## 2. Mac 真实登录验证

使用本机已有 Command Line Tools、macOS SDK、Swift、AppKit 和 WebKit 编译临时程序。没有安装 Flutter、Xcode、Python 包或 OCR 依赖。

验证程序和源码位于 `/private/tmp/rain-client-s0/`。使用 `WKWebsiteDataStore.nonPersistent()`，不读取、复制 Edge 既有登录状态，不将会话写入磁盘、剪贴板或系统钥匙串。

步骤：

1. 在独立 `WKWebView` 中加载 `https://changjiang.yuketang.cn/web`。
2. 验证原生 Cookie API 能读写临时的、无授权能力的 HttpOnly 测试 Cookie。
3. 由用户在官方页面正常扫码登录。
4. 通过该窗口自己的 `WKHTTPCookieStore` 取得会话，检查其存在性及 Secure / HttpOnly 标记。
5. 用户点击“只读验证会话”，使用独立的临时 `URLSession` 请求 `GET /v2/api/web/userinfo`，只携带 `sessionid`。
6. 检查 HTTP 状态和响应内有效用户记录的存在性，不输出原始响应、姓名、标识或 Cookie 值。
7. 保存结果摘要，再清除该窗口的临时会话并关闭程序。

结果快照见 [Mac 登录验证摘要](verification/client-s0-mac-login.json)，包括程序源码的 SHA-256，便于区分后续试验版本。

这里的“通过”表示该会话可供浏览器之外的 HTTP 客户端访问一个只读账号接口。没有调用课程发现与签到混合入口，没有进入课堂、提交任何内容或验证业务评分。

这足以支持继续验证 Flutter Mac 登录容器；不能外推到 Android、会话持久化、会话有效期或自动续期。

## 3. GitHub：新的可行路线与权限问题

已读取 GitHub 渲染后的官方 OAuth 文档，并在用户当前已登录的 GitHub 注册页面核对可用配置。

已确认的协议事实：

- OAuth App 支持设备授权；设备授权的令牌交换不需要 Client Secret。
- 当前官方文档支持过期访问令牌与刷新令牌；文档说明访问令牌约 8 小时有效，刷新令牌使用期限另有规则。
- 对设备授权产生的令牌，刷新请求也不要求 Client Secret。这为 Worker 在客户端关闭后自行刷新提供了协议基础。
- 刷新会使旧令牌对失效；实现时必须正确保存新令牌，处理并发刷新、响应丢失和撤销，不能只把短期访问令牌静态写入 Worker。
- 当前注册页面提供 Enable Device Flow 和 Expire user access tokens；本次观察到新建表单的过期选项默认选中。

2026-10-26 已使用本项目注册的测试客户端完成低权限授权与立即刷新，结果见 [GitHub 验证摘要](verification/client-s0-github-device.json)：

- 设备授权、访问令牌交换、刷新请求均返回 HTTP 200。
- 实际授予的 scope 只有 `read:user`，没有仓库或工作流权限。
- 访问令牌返回有效期 28800 秒，同时返回刷新令牌；未等待 8 小时，而是立即发起刷新。
- 未发送 Client Secret；刷新后访问令牌、刷新令牌均发生轮换。
- 新令牌的只读身份请求返回 HTTP 200，与刷新前为同一账号；旧访问令牌返回 HTTP 401。
- 凭据只在独立 Node 验证进程的内存中处理，结果文件不含令牌、身份原值或完整接口响应。

测试结束后已在该新建应用内提交撤销所有用户令牌的请求，GitHub 显示 `Job queued to revoke all user tokens`。这表示撤销任务已接受，最终完成状态未另做令牌请求复核。本地验证服务已停止，应用注册本身保留供后续测试使用。

这份首轮 OAuth App 证据证明设备授权令牌可由独立程序完成无客户端密钥刷新，本身不覆盖 Worker、真实 dispatch 或仓库管理。后续 GitHub App 的云端实测另列如下；并发刷新、响应丢失恢复和长时间运行仍未验收。

### 权限仍需作出具体选择

官方 Secrets 写入、工作流启用与 dispatch 接口文档对经典 OAuth 令牌列出了 `repo` 范围。OAuth 的 `repo` 权限较宽，不能在未实测时承诺仅申请 `public_repo` 就覆盖全部配置操作。

GitHub App 可把安装权限限制到选定仓库；其安装令牌约 1 小时有效，需要用 App 身份重新签发。这与本次已验证的 GitHub App 设备授权用户令牌是两条路径：后者返回八小时访问令牌和刷新令牌，刷新不需要 Client Secret。官方 Manifest 流程可帮助用户注册预配置的个人 App，但这条每用户一个 App 的备选路线没有执行，也未验证完整自动创建 Fork 流程。

该低权限轮次验证了设备授权与立即刷新；完整调度和管理身份的后续实测见下文。不能为了方便直接把广泛仓库权限作为已经确定的默认配置。

### GitHub App 调度身份：第二轮功能验证通过

2026-10-27，用户明确批准后，已创建两个公开空测试仓库：`frewily/rain-client-s0-target-20261027` 和 `frewily/rain-client-s0-control-20261027`。仅放置手动触发的空工作流，没有真实凭据、课堂数据或 Cron。准备工作使用既有 GitHub CLI 和 SSH 身份完成，不能把它算作新 App 的写代码能力。

用户注册私有测试 App `Rain S0 Scheduler 20261027`，App ID 为 `5489930`，启用设备授权。安装页已核对权限只有 Actions 读写和 Metadata 只读；用户仅选中 target 仓库。注册成功页存在生成私钥的通用提示，但本次未执行生成私钥，仍成功进入安装并完成授权范围核验。

第一次设备授权的真实结果：无 Client Secret 的立即刷新返回 200，访问和刷新令牌均轮换，新令牌为同一账号，旧访问令牌返回 401。实际安装列表只有 target，权限为 `actions: write`、`metadata: read`。

向 target 提交的唯一一次 dispatch 返回 200。临时脚本沿用了旧版 204 判断而误报失败；随后从本次使用的 `2026-03-10` 官方文档确认 200 是成功返回值，并通过只读运行查询确认 [空任务 40448466689](https://github.com/frewily/rain-client-s0-target-20261027/actions/runs/40448466689) 已成功完成，提交为 `643a01c40f6ceb4b953036dfc5dcc1f8541193ac`。

随后使用同一 App、同一权限重新进行一次设备授权，续测程序再次验证刷新与安装范围，复用 target 既有运行记录，只向 control 提交唯一一次触发请求，返回 HTTP 403。持久化次数保护阻止重复触发 target。恢复额度后又通过只读查询核对：target 总共 1 次运行且成功，control 为 0 次运行。

脱敏证据见 [GitHub App 调度身份验证摘要](verification/client-s0-github-app-scheduler.json)。两次授权都验证了无 Client Secret 的立即刷新、令牌轮换、身份一致及旧访问令牌返回 401；未等待八小时，也未在 Worker 中执行。

清理结果单独记录：用户已在该测试 App 中执行 `Revoke all user tokens`。原定的两个令牌失效检查因自动审批达到使用限额而未执行；额度恢复前，两个程序均已达到 30 分钟保留上限并丢弃令牌持有值，因此无法再用原令牌补验撤销。当前两个临时进程已停止，8765、8766 均无监听。结论为“用户已报告撤销、本地凭据持有已结束，服务端失效未独立复核”，不能写成两个令牌都已实测返回 401。

私有 App 注册及两个空测试仓库按约定保留。现有业务仓库、生产 Worker、Secrets、Cron 和真实课堂均未参与。此结果支持继续验证独立 Worker 的 GitHub App 用户令牌刷新与调度，不覆盖部署管理权限、公开 App 跨账号授权或长期云端可靠性。

### 独立 Worker：云端刷新、空任务与清理通过

2026-10-27，用户逐项批准后，通过 Cloudflare 控制台手工部署独立 Worker `rain-client-s0-worker-20261027`，只配置随机调用口令 `PROBE_KEY`。没有增加 KV、D1、Durable Object、Cron、DNS 或付费配置，也未扩展 Cloudflare OAuth 权限。最终版本为 `rain-s0-worker-github-20261027-v3`，运行源码为 [worker-runtime.mjs](verification/worker-probe/worker-runtime.mjs)，验证程序使用校验过的只读快照供用户复制。

真实执行结果见 [Worker 运行摘要](verification/client-s0-worker-runtime.json)：

- 本机只取得新的设备授权令牌，没有执行刷新；临时凭据通过 HTTPS 交给本人测试 Worker，在内存中处理。
- Worker 验证实际安装范围仅 target、权限为 Actions 读写和 Metadata 只读；固定空工作流的内容摘要匹配。
- Worker 刷新返回 HTTP 200，访问令牌和刷新令牌均轮换；新令牌为同一账号，旧访问令牌返回 401；未发送 Client Secret。
- Worker 使用 `2026-03-10` API 向固定 target 提交一次 dispatch，返回 200；[空任务 40510756580](https://github.com/frewily/rain-client-s0-target-20261027/actions/runs/40510756580) 成功完成，提交仍是 `643a01c40f6ceb4b953036dfc5dcc1f8541193ac`。
- 独立只读回查显示 target 从 1 次增加到 2 次成功运行，control 仍为 0 次运行。Worker 本轮没有请求 control。
- 刷新后的新令牌对经 HTTPS 返回本机内存，仅用于有效性和撤销检查，不写入文件、仓库或云存储；Cloudflare 中保留的 Secret 仅为调用口令。

首次云端请求在刷新和触发前失败，没有新增运行。原因已由真实 Worker 诊断确认：Workers 不支持 `redirect: "error"`，应使用 `manual` 并显式拒绝 3xx。查明没有进入刷新或调度后，保留首次尝试记录，以新版本和新授权受控续测。整个阶段共两次 `/probe` POST，只有成功轮进入刷新及 dispatch；没有对未知的触发结果自动重试。

本地表单也曾因 `no-referrer` 让 Edge 提交 `Origin: null` 而被本地来源检查拒绝；已改为 `same-origin`，保留来源检查并在内存中接续原口令。匿名公开 API 的读取曾出现 403，未从当次响应独立确认原因；后续只读对照两个地址均返回 200。最终改为读取 GitHub 官方原始文件并校验同一内容摘要，本机观察运行时另核对目标提交。诊断与源码回写观察见 [调试证据](verification/client-s0-worker-debug.json)。离线检查最终为 20 项通过，不能以它们代替上述真实运行证据。

收尾结果：成功轮用户撤销后，本地自动检查刷新后的新访问令牌返回 401，随后丢弃持有值。测试 Worker 的 Production Worker URL 入口已关闭，Preview URL 本来即关闭；公开 `/health` 返回 404，2026-10-28 再次复核仍为 404。本地准备程序与表单诊断程序已停止，8765、8770 无监听。测试 Worker、随机调用口令配置、GitHub App 和两个空仓库保留。首次失败轮的撤销由用户报告完成、令牌持有值按时丢弃，其失效没有独立补验，不与成功轮的 401 证据混用。

这证明一次请求内的 GitHub App 云端刷新与触发可实现，不证明刷新令牌持久保存、客户端关闭后的长期 Cron 调度、并发刷新、响应丢失恢复、自动部署权限或公开跨账号绑定已完成。

### 已经确认注册的首轮 OAuth 测试应用

GitHub 页面：`https://github.com/settings/applications/new`。

| 字段 | 草稿内容 |
| --- | --- |
| 名称 | `Rain Client S0 - 20261026` |
| 主页 | 当前项目 GitHub 地址 |
| 回调 | `http://127.0.0.1:8765/github/callback`，设备授权初测不依赖该回调 |
| Device Flow | 已启用 |
| 访问令牌过期 | 保留页面默认启用 |
| 首次授权目标 | 只读账号身份与离线刷新，不申请仓库写入权限 |

用户已明确允许注册并进行低权限测试，随后已提交注册。实际设置页面确认应用由本人拥有，公开 Client ID 已生成，未创建 Client Secret。设置地址为 `https://github.com/settings/applications/3964347`，便于继续验证或管理该测试应用。

临时验证程序仅请求 `read:user offline_access`，令牌只在内存中处理。首次尝试在网络连接阶段失败。排查确认：macOS 设置了本机代理，但该 Node 进程未继承代理环境；Node 直连返回 `UND_ERR_CONNECT_TIMEOUT`。仅为验证进程设置现有代理后，公开入口检查返回 HTTP 200 且完整响应已读完；随后由用户在官方页面完成授权并通过上述刷新测试。保留 TLS 校验，没有修改全局网络设置。

### GitHub 管理身份：配置、Secrets 与真实任务验证通过

2026-10-28，主人明确批准本轮管理验证与临时加密依赖安装。私有 App `Rain S0 Manager 20261028`（App ID `5504900`，公开 Client ID `Iv23li36LZrIGh5lZQOR`）仅安装 target；实际权限复核为 Actions、Administration、Contents、Secrets、Workflows 写与 Metadata 读。调度 App 的权限保持原范围。

使用该管理 App 的设备授权用户令牌，实际完成了：

- 校验本人身份、精确安装范围与权限；未安装的 control 仓库 Secrets 公钥请求返回 403。
- 暂时关闭 target 的 Actions，读取确认，再恢复原策略并完整回读。
- 创建一份合成 JSON 配置及一份仅支持手动触发的测试工作流，分别回读内容；没有使用真实业务配置。
- 使用 PyNaCl sealed box 加密随机合成 Secret 并写入，读取其元数据。工作流没有 checkout、第三方 Action、Cron 或业务请求；Runner 内仅对比 Secret 的 SHA-256，不输出原值。
- 唯一一次 dispatch 返回 200；[测试任务 40627711899](https://github.com/frewily/rain-client-s0-target-20261027/actions/runs/40627711899) 实际成功，确认任务确实取得了该 Secret。
- 删除本轮 Secret、工作流和配置文件并确认不存在。成功轮撤销后，原访问令牌独立检查为 401，进程退出，专用临时 Python 环境已删除。

独立只读回查确认：当前文件树与原提交 `643a01c40f6ceb4b953036dfc5dcc1f8541193ac` 相同，清理后 HEAD 为 `6adef24985f21fdecc3ad5bf16262c46ea509b08`；正常测试提交历史保留。target 共 3 次成功运行，分别来自调度本机轮、Worker 轮及本管理轮；control 仍为 0。证据见[完整收尾摘要](verification/client-s0-github-manager-runtime.json)与[成功轮 API 记录](verification/client-s0-github-manager-attempt3.json)。

此前两轮均在首次 Actions 开关写入后停止，没有创建文件／Secret、没有触发任务。诊断明确得到 409 `Conflict`；对照后确认关闭时应只提交 enabled，且关闭响应会省略 allowed_actions。v3 修正请求与读取逻辑，先复现失败再通过 33 项本地检查，随后才得到上述真实成功结果。参数对照使用已有仓库所有者身份，单独记录，不冒充管理 App 能力；首轮撤销独立核验 401，第二轮因执行会话中断仅保留用户报告撤销，成功轮独立核验 401。这些边界见[本轮方案与排查记录](client-app-github-manager-probe-plan.md)。

本轮证明本人账号中，软件可通过这一管理身份在指定仓库保存配置并让任务读到 Secret。没有验证自动 Fork、跨账号公开安装、已有文件冲突合并、Flutter 界面或 Cloudflare 自动部署。

## 4. Cloudflare：协议与实际账号验证的边界

官方第三方 OAuth 文档明确支持：

- 原生桌面、手机客户端使用 Authorization Code + PKCE，`S256`，令牌端点认证方式为 `none`。
- 公开客户端允许账号外用户授权，但项目方需要完成项目域名所有权验证。
- 私有客户端只能由所属 Cloudflare 账号成员授权，可先用于本人的初测。
- 用户可以选择被授权的账号、检查请求权限并撤销授权。

公开访问 `https://dash.cloudflare.com/.well-known/openid-configuration` 也实际返回了授权、令牌和用户信息端点，以及 `S256`、`none` 等能力。

需要注意：这份公开元数据还列出设备授权等模式，但官方第三方客户端文档明确限制了可用流程。不能把服务端公布的全部模式，视为本项目自建客户端都可以使用。Cloudflare 仍按官方的原生客户端 PKCE 路线验证。

已在本人已登录的 Cloudflare 账号中核对授权码流程与 `None (PKCE)` 选项。用户明确允许后，已创建名为 `Rain Client S0 - 20261026` 的私有测试客户端，仅配置 `User Details Read`，并取得公开 Client ID。2026-10-27 已完成真实授权回调、令牌交换与只读身份检查。未创建 Client Secret，未转为公开客户端。

本项目公开 Client ID 已取得，回调地址已配置为 `http://127.0.0.1:8765/cloudflare/callback`。2026-10-27 已启动仅监听本机的临时验证程序，并实际到达官方 `Consent Application` 页面。初次请求未显式提供 `scope`，官方页面显示 `0 total permissions`，提示至少选择一项权限，`Authorize` 因此被禁用。本地程序未收到授权回调，没有执行令牌交换或身份请求。

随后从该客户端的官方权限详情核对到 `User Details Read (user-details.read)`，只给临时验证程序补充 `scope=user-details.read`。对本地页面实际生成的授权链接检查，修改前失败、修改后通过；PKCE S256、回调地址和无客户端密钥保持原样。官方确认页随即显示唯一权限 `User Details Read`，`Authorize` 恢复可用，验证了按钮禁用的原因。先前页面自行返回首页的原因没有独立确认。

用户随后在官方页面完成授权。脱敏结果见 [Cloudflare PKCE 验证摘要](verification/client-s0-cloudflare-pkce.json)：

- 本地回调校验 `state` 成功，收到授权码；无 Client Secret 的授权码交换返回 HTTP 200。
- 实际授予的权限只有 `user-details.read`，访问令牌返回有效期 3599 秒。
- 独立 HTTP 客户端请求 `GET https://api.cloudflare.com/client/v4/user` 返回 HTTP 200，`success=true` 且存在有效用户记录；不保存用户标识、邮箱或原始响应。
- 本次请求没有包含 `offline_access`，响应未返回刷新令牌，因此没有执行刷新；这不能证明 Cloudflare 不支持刷新。
- 对此次访问令牌调用官方撤销端点返回 HTTP 200，再以同一令牌请求同一用户信息接口返回 HTTP 403。令牌持有值随后已从程序变量丢弃，本地验证服务已停止；测试客户端注册保留。未独立检查控制台的 Connected Applications 是否仍保留同意记录，不能把令牌失效等同于该记录已删除。

用户看到的 `Callback already handled` 来自临时程序对后续回调的保护：首次回调处理后，重复请求会返回 HTTP 409，不再交换授权码。真实结果文件显示首次回调、令牌交换、只读访问及撤销均已完成；返回官方页面后显示的 `authorizing` 不能替代这些后台证据。重复回调具体由刷新、返回还是其他浏览器行为触发，没有独立确认。

待验证内容包括令牌刷新条件、Worker / KV / D1 / Secrets / Cron 的具体 scope、公开客户端的域名验证与非所属账号授权。此次只读身份验证不覆盖资源管理、Worker 运行或 Android 回调。

初测优先准备私有 PKCE 客户端和只读权限，不改变现有应用的公开性、不操作生产资源。域名验证和转公开留到本人授权通过之后，再明确具体操作。

2026-10-28 后续独立管理验证已通过本人账号的资源自动部署。首轮使用 Workers Editor 上传返回 403；主人单独批准仅替换为 Workers Admin 后，第二轮上传返回 400／10021，存储和令牌均清理。对照官方示例修正 ES module 部分类型为 `application/javascript+module` 后，第三轮无绑定编译上传返回 200，继续完成 KV／D1／Secret／入口配置，真实 Worker 请求的两项存储摘要均匹配。20 项本地检查与真实云端结果分别保存；首轮 403 的精确原因仍不补作断言。

成功轮 Secret、KV、D1 均已删除并回读；保留空 Worker `rain-client-s0-deploy-20261028-58f9c6316cc1`，绑定为空，workers.dev／Preview 关闭，另一次公开入口检查返回 404。令牌撤销 200，原个人信息接口从 200 变为 403，内存引用丢弃、本地服务退出。见[完整方案与三轮结果](client-app-cloudflare-manager-probe-plan.md)、[成功轮 API 记录](verification/client-s0-cloudflare-manager-attempt3.json)和[运行摘要](verification/client-s0-cloudflare-manager-runtime.json)。本轮没有 Cron、DNS、公开跨账号授权或真实业务数据。

## 5. 开发与发布环境

本机实际可用的是 Command Line Tools 和 macOS SDK，足以完成上述原生小程序验证。

初次预检时 PATH 未发现 Flutter／Dart／adb，标准 Android SDK 目录不存在。2026-10-28 主人明确批准按通用目录安装，并亲自阅读同意本轮 Android SDK 许可证后，已完成 Flutter 3.47.8／Dart 3.13.7 及固定 Android 组件安装。Flutter 位于 `/Users/frewily/Library/Developer/flutter/3.47.8`，Android SDK 位于 `/Users/frewily/Library/Android/sdk`，依赖缓存与 debug keystore 独立存放；没有修改全局 PATH 或 Java。

Flutter doctor 的 Android toolchain 检查通过。临时合成界面静态分析和 1 项行为测试通过，实际构建的 `top.frewily.rainclient.probe` debug APK 包名、最低 API 24、三种 CPU 架构及签名均核验通过。初次构建后主人选择稍后连接手机，随后反馈测试包点击计数与退出重开归零均正常；这是用户报告，尚未独立连接设备或核对设备信息，不外推到雨课堂登录、回调或安全存储。

当前选中的 Apple 开发目录仍为 Command Line Tools，完整 Xcode、Android Studio 和模拟器未安装；先前代码签名身份检查返回 0 个有效身份，正式发布条件仍单独验证。

这些结果说明：

- Mac 原生能力可以先验证，当前已经完成上述一项。
- Android 编译已通过，真机运行待连接；Flutter Mac 编译仍需要完整 Xcode，不能把本轮结果当作两端应用测试。
- 后续若安装 SDK，先给出来源、目录、体积和修改计划，确认后再执行。
- GitHub Releases 发布与 Mac 安装包签名 / 公证分别验证，不能用临时本地程序能运行代替下载后的安装验收。

2026-10-28 的[脱敏预检](verification/client-s0-flutter-device-preflight.json)保留安装前的现状和候选版本；后续批准、实际路径、固定版本、下载排查、静态检查、APK 和未验证项见[Flutter 与真机安装方案](client-app-flutter-device-probe-plan.md)及[执行证据](verification/client-s0-flutter-device-runtime.json)。原始完整 Flutter ZIP 超时，实际改用同一官方标签及精确提交安装；Google Maven 的 Java 默认代理 404 经直连 200 对照修复，工具和依赖版本未降低。约 10.77 GiB 是 SDK、缓存、下载包和临时工程合计占用，APK 约 143.4 MiB，不混作应用安装体积。

## 6. 下一轮需要的实际操作

GitHub 低权限设备授权与立即刷新、Cloudflare 私有 PKCE 授权与只读身份检查已完成。Cloudflare 本次未返回刷新令牌，后续需核对离线授权及客户端配置后单独验证，不能将其记为已通过。真实凭据只在验证程序内存中处理，不写入现有生产 Secrets。

GitHub App 的本机调度身份、独立 Worker 内立即刷新与空任务触发，以及独立管理身份的配置／工作流／Secrets／Actions 验证均已完成。Cloudflare 新管理客户端也已完成本人账号发现、自动部署和 Worker 实际读取 KV／D1。Flutter／Android 雨课堂登录已有主人真机反馈通过；GitHub 绑定和仓库识别现也完成初版代码及开发包，下一步是在手机上验证其官方授权与本机恢复；不能直接视为完整客户端或云端部署已完成。Mac 等完整 Xcode 就绪后单独构建。调度 App 继续只保留 Actions 权限。自动 Fork、云端刷新令牌持久化、长期 Cron、私有业务数据接入与公开跨账号授权仍分别验证。

2026-10-29 已按双方约定的协作流程整理[安卓登录方案](client-app-android-login-plan.md)，主人确认本机退出与云端停用分开，并明确批准四项固定插件及实现。现已建立 `apps/client`，完成官方登录容器、固定站点 Cookie 读取、只读检查、安全存储、恢复／重试／清除和过期回调保护；静态分析和 26 项合成行为测试通过。无会话／合成失效会话两次真实只读对照分别返回 401／业务码 401002、401000，没有发送真实凭据或保留原始响应。ARM64 Release 开发包 16.54 MB，开发签名、包名、ABI、ZIP／ELF 16KB 对齐均核验通过。[执行证据](verification/client-s0-android-login-runtime.json)与[源码摘要](verification/client-s0-android-login-source.json)记录实际产物。

JNI 编译复用已有 API 36，原生编译复用既有 REA CMake 3.31.6／Ninja，没有新增 SDK/JDK 或修改其他项目。主人报告的目标设备是一加 Ace5 至尊版、Android 16，随后报告四个交付步骤通过，包括真实登录、重开恢复和本机退出；未独立读取设备或会话，具体微信返回路径和断网恢复未单独报告。[手机验收表](client-app-login-acceptance.md)保留各项证据边界。窄屏显示调整已写入，按主人要求不为此再次交付 APK，后续优先接入 GitHub 绑定及仓库识别，再推进 Cloudflare 和云端配置。合成预览不作为设备或 Mac 窗口运行证据，本轮未写云端或提交／推送 Git。

其后已完成[GitHub 绑定与仓库识别](client-app-github-binding.md)的本地实现，0.2.0 功能包同时带上显示调整，不要求单独重测雨课堂。累计 66 项行为测试和手机尺寸合成预览通过，真实 GitHub 凭据尚未在本轮处理；原超时影响新操作的回归用例修复前失败、修复后通过。APK 与原版签名一致、版本号递增，开发包及源码摘要见[本轮记录](verification/client-s0-github-binding-runtime.json)。后续先验收这段，再继续 Cloudflare 客户端与部署配置；本轮未增加依赖、权限或生产写操作，未提交／推送 Git。

2026-10-30 已收到 GitHub 四步全部通过的[主人真机反馈](verification/client-s0-github-binding-human-acceptance.json)，该段不再作为等待验收的阻点。下一段聚焦[Cloudflare 官方授权、手机返回、账号识别与本机恢复](client-app-cloudflare-binding.md)，之后再进入实际云端配置；本次反馈未验证真实凭据更新、资源部署或长期调度。

之后按“完整可用功能”合并推进，在 0.3.0 中完成[测试环境部署与空任务结果](client-app-test-deployment.md)的本地实现。98 项测试、回环 HTTP 回调、生成的模块／工作流语法、合成手机预览和 17.59 MB 开发 APK 核验通过；只有当前真实云端结果仍需手机验收。测试使用新随机 Worker 与原空测试仓库的单份工作流，源码和 API 边界不操作生产资源、Secrets 或课程；具体清单由手机用户确认后才写入。[执行和源码摘要](verification/client-s0-test-deployment-runtime.json)。

独立 Worker 的[原测试范围与执行结果](client-app-worker-probe-plan.md)已完成收尾：最终 20 项离线检查通过，真实云端成功轮及清理证据另存。其手工部署不证明自动部署；自动部署依据是后续独立 Cloudflare 管理成功轮，二者分别记录。

GitHub 低权限测试、Cloudflare 私有只读测试、GitHub App 与指定空仓库、测试 Worker 的云端验证，以及本轮明确列出的 Flutter／Android 固定工具、临时程序与测试 APK 均已获准。进一步扩大仓库或 Cloudflare 资源权限、修改 DNS、将应用转公开、创建其他资源、增加未列 SDK／插件、提交或推送本业务仓库仍未默认获准。Xcode 由主人在官方渠道准备，协议和首次启动由主人完成。

2026-10-27 的[权限核对与测试范围](client-app-permissions-and-next-probe.md)保留了本轮方案和 API 权限清单。执行结果表明，GitHub App 用户令牌的设备授权、无客户端密钥刷新和指定仓库调度均可在本项目中实现；原有 OAuth App 的低权限测试与本轮证据分别保存。

## 7. 主要依据

2026-10-28 的 Cloudflare 管理三轮结果另见[本轮方案及权限对照续测](client-app-cloudflare-manager-probe-plan.md)和[运行摘要](verification/client-s0-cloudflare-manager-runtime.json)。第三轮实际授权、部署、绑定读取、资源清理及撤销均已通过；设置保存、本地检查与真实云端结果分别记录。

- [本项目客户端方案](client-app-plan.md)。
- [GitHub OAuth 授权与刷新](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)。
- [GitHub OAuth scopes](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)。
- [GitHub Actions Secrets 接口](https://docs.github.com/en/rest/actions/secrets)。
- [GitHub Actions workflow 接口](https://docs.github.com/en/rest/actions/workflows)。
- [GitHub App Manifest 注册](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest)。
- [Cloudflare 创建 OAuth 客户端](https://developers.cloudflare.com/fundamentals/oauth/create-an-oauth-client/)。
- [Cloudflare OAuth 集成端点](https://developers.cloudflare.com/fundamentals/oauth/integrate-with-cloudflare/)。
- [Cloudflare 官方公开元数据](https://dash.cloudflare.com/.well-known/openid-configuration)。
