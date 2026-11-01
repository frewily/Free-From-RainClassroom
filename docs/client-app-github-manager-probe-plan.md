# 阶段 0：GitHub 客户端管理能力最小验证

日期：2026-10-28。状态：v3 管理 App 真实验证已通过并完成收尾。配置／工作流／加密 Secret 写入成功，唯一一次新增任务实际成功，测试数据删除、策略恢复、成功轮令牌 401、进程退出、临时环境删除均已核验。App 注册及原测试仓库保留，完整结果见[运行摘要](verification/client-s0-github-manager-runtime.json)。

## 对应的软件功能

验证用户在软件中填好配置后，软件能否将配置及 Secrets 保存到选定仓库、写入工作流、启用仓库 Actions，并看到任务确实读到了配置。只使用合成数据；本轮不使用雨课堂 SESSION、课程记录、邮件密码或其他真实业务配置。

前一轮已证明调度 App 可在 Worker 内刷新并触发任务。本轮单独验证部署所需的管理权限，不扩展原调度 App，也不向 Worker 交付管理凭据。通过本轮不等于 Flutter 客户端、自动 Fork 或完整部署向导已经完成。

## 已批准的变更清单

| 项目 | 精确范围 |
| --- | --- |
| 新私有 GitHub App | `Rain S0 Manager 20261028`，本人测试；启用 Device Flow 和用户令牌过期，关闭 Webhook，不生成 Client Secret 或 PEM 私钥 |
| 仓库权限 | Actions、Administration、Contents、Secrets、Workflows 五项均为 Read and write；Metadata 为基础 Read-only；其他仓库、账号、组织权限均不选 |
| 安装范围 | 只安装到既有公开空仓库 `frewily/rain-client-s0-target-20261027`；不选 All repositories |
| 对照范围 | 仅向未安装的 `frewily/rain-client-s0-control-20261027` 请求 Secrets 公钥，预期 403/404；不写入、不触发任务 |
| 目标 Actions 开关 | 先确认无运行中的任务；记录原策略，暂时关闭，再立即恢复并回读。保留原 allowed_actions、sha_pinning_required；selected 策略额外核对原规则 |
| 目标文件 | 新建 `.rain-client-s0/manager-20261028-<随机编号>.json` 和 `.github/workflows/s0-manager-20261028-<随机编号>.yml` 各一份；已有同名路径则停止，不覆盖 |
| 目标 Secret | 新建 `RAIN_S0_MANAGER_20261028_<随机编号>`；值为本机生成的随机合成数据，经仓库公钥 sealed box 加密后上传 |
| 任务 | 最多触发一次新工作流；只有手动触发，无 checkout、第三方 Action、定时任务或业务接口。Runner 内对比 Secret 的 SHA-256，只输出通过或失败 |
| 云端清理 | 删除本轮创建的两份文件和随机 Secret，回读确认；恢复并核对 Actions 策略。测试提交及运行历史、App 注册、既有两仓库保留 |
| 授权清理 | 用户在官方页撤销新管理 App 的用户令牌；测试结束后程序每 15 秒只读检查一次，最多等待 15 分钟，确认 401 后丢弃临时引用；不在文件中保存访问／刷新令牌 |
| 临时安装 | 只在 `/private/tmp/rain-client-s0/github-manager-venv` 新建 Python 环境，安装下表三包及其全部依赖；不改系统 Python、已有环境或生产依赖清单；测试结束删除该临时环境 |

这些管理权限具有对应仓库范围内的实际写能力，包括较宽的 Administration 和 Actions 能力；测试程序的接口白名单不是平台权限的进一步裁剪。生产仓库、现有 Scheduler App、Cloudflare 资源均不参与。

两次文件创建和两次删除会在空测试仓库留下正常提交历史；清理只恢复文件和设置，不抹除 Git 历史。若 GitHub 写入结果不明，先回读，不盲目重发；若恢复被拒绝或文件被别人修改，程序保留现场并报告待处理项，不声称全部清理完成。

## 临时依赖与来源

当前解释器为 Python 3.14.4／macOS arm64。GitHub Secrets 要求使用 libsodium sealed box；本机没有 PyNaCl／可用系统 libsodium，因此使用 PyPI 官方预编译 wheel，不自行实现加密。

| 包 | 固定版本 | 安装文件 |
| --- | --- | --- |
| PyNaCl | 1.6.2 | `pynacl-1.6.2-cp38-abi3-macosx_10_10_universal2.whl` |
| cffi | 2.1.1 | `cffi-2.1.1-cp314-cp314-macosx_11_0_arm64.whl` |
| pycparser | 3.12 | `pycparser-3.12-py3-none-any.whl` |

三份 wheel 共约 0.61 MiB，不含临时环境自带的 Python／pip 文件。官方下载地址和 SHA-256 见 [依赖清单](verification/manager-probe/dependency-plan.json)，锁定值见 [requirements.lock](verification/manager-probe/requirements.lock)。安装时使用仅二进制、强制哈希校验、不使用缓存的选项；不执行源码构建。环境目录存在则先核对，不覆盖未知环境。先做本地合成加密／解密往返，再开始账号授权。

## 注册时可复制的字段（本轮实际使用）

- GitHub App name：`Rain S0 Manager 20261028`
- Homepage URL：`https://frewily.top`
- Description：`Private stage-0 test for managing one empty Rain Client test repository.`
- Callback URL：留空；本轮只使用 Device Flow。
- Expire user authorization tokens：勾选。
- Enable Device Flow：勾选。
- Webhook / Active：取消；不填写 Webhook URL。
- Repository permissions：Actions、Administration、Contents、Secrets、Workflows 为 Read and write；Metadata 自动 Read-only。
- Account permissions、Organization permissions、Subscribe to events：不选。
- Where can this GitHub App be installed?：Only on this account。

注册后只需要公开的 App ID／Client ID，不需要发送任何密钥。若平台要求额外字段或必须生成私钥则先停下，核对当前页面再继续。安装只选 target 仓库；设备授权时提供实际一次性验证码和北京时间到期时间。

## 程序与验收

- [probe.mjs](verification/manager-probe/probe.mjs)：固定仓库与接口边界，校验权限、基线、空闲状态、写入与回读，观察 Runner，执行清理。
- [live.mjs](verification/manager-probe/live.mjs)：获准后的设备授权与代理传输；导入时无网络调用，直接启动要求显式批准标记和公开 App 标识。
- [seal.py](verification/manager-probe/seal.py)：只通过 stdin 接收仓库公钥／合成明文，stdout 只输出密文；自检只返回布尔结果。
- [probe.test.mjs](verification/manager-probe/probe.test.mjs)：本地模拟接口测试。真实 PyNaCl 往返、平台权限和 Runner 均需在获准后验证。

一次运行锁位于 `/private/tmp/rain-client-s0/github-manager/attempt-20261028.json`，使用排他创建，防止进程重启后重复测试。脱敏进度写入同目录 `result.json`。凭据只留进程内存，通过 HTTPS 发送到 GitHub；传输放在子进程 stdin，不出现在进程参数、仓库文件或输出中。没有本地网页服务。

当前 target 预期基线为 `643a01c40f6ceb4b953036dfc5dcc1f8541193ac`。若已有其他提交、活动运行、额外安装范围或权限，程序在写入前停止；不能为了绕过检查默认更新基线或扩大权限。

验收分别记录：实际 App／安装权限、对照拒绝、普通文件回读、工作流回读、Secrets 元数据、Runner 内核验、策略恢复、临时文件／Secret 清理、撤销后 401、临时环境删除。任何一项未实测都单独标为未完成。

前置官方权限依据见[权限核对](client-app-permissions-and-next-probe.md#2-github-的权限边界)。本轮不涉及自动 Fork、新建仓库、Cloudflare 部署、长期令牌保存、Flutter／Android 验证或本业务仓库的提交与推送。

2026-10-28 执行前的本地准备快照：当时 28 项模拟检查通过；生成的工作流已解析，内部核验脚本已用合成正确值／错误值分别确认通过／拒绝。该快照中的加密 helper 仅检查语法，真实加密往返、GitHub 管理接口与真实 Runner 当时尚未运行；后续执行及收尾结果见本节后文。[准备证据与源码摘要](verification/client-s0-github-manager-preparation.json)。

后续执行进展：主人已批准上述完整范围。临时 Python 环境仅安装 PyNaCl 1.6.2、cffi 2.1.1、pycparser 3.12 及环境自带 pip，哈希校验安装完成、`pip check` 通过；helper 自检及真实 stdin 输入／密文输出／合成私钥解密校验均通过，执行前源码与准备证据中的 SHA-256 一致。该环境已用于真实 GitHub 验证，收尾后已按约定删除。[本轮运行结果](verification/client-s0-github-manager-runtime.json)。

首轮 App ID 为 `5504900`、公开 Client ID 为 `Iv23li36LZrIGh5lZQOR`、安装 ID 为 `176037329`。实际 GitHub App 用户令牌的安装权限和仓库范围复核通过，对照 Secrets 公钥请求为 403。[首轮证据](verification/client-s0-github-manager-attempt1.json)仅记录 `write_rejected`，缺少该响应状态，不能推断为某种特定权限或参数错误。

诊断续测仍使用同一 App 和五组仓库写权限，不新增资源、不扩大安装范围。v2 为写入结果增加 HTTP 状态、预期状态、固定分类及错误消息摘要；不保存原始响应或凭据。独立续测锁只允许从首轮“1 次写入尝试、0 次 dispatch、已确认清理、已独立确认撤销 401”的状态继续一次；原锁与首轮结果保留。尚未改变导致失败的请求参数；先取得真实响应证据再判断修复。

第二轮与参数对照：管理 App 原请求返回 409，错误消息 SHA-256 对应固定消息 `Conflict`。随后使用现有仓库所有者 CLI 做独立参数对照：原参数同样 409，且消息摘要相同；改为只提交 `{"enabled":false}` 后为 204，回读为 `enabled:false` 并省略 `allowed_actions`；提交原策略后恢复 204，最终回读与基线一致。该对照没有触发工作流，且不计为管理 App 能力通过。证据见[第二轮](verification/client-s0-github-manager-attempt2.json)和[参数对照](verification/client-s0-github-manager-policy-control.json)。

v3 只改关闭请求的参数及关闭后响应的读取：保留关闭前快照，关闭时只发送 enabled，允许关闭后的响应省略策略字段，恢复后完整核对原策略。先新增按真实 API 行为的失败用例，再修复并通过全部 33 项本地检查。独立修复续测锁要求第二轮仍为 0 次 dispatch、清理已确认、409 对照及恢复证据齐备，并确认前轮授权已撤销；若原执行会话丢失，用户报告撤销与独立 401 证据分开记录，不能补写不存在的核验结果。

## 成功轮及最终收尾

修复版继续使用同一管理 App 与安装范围。实际 Actions 关闭／恢复均为 204，两份文件创建均为 201 且内容回读一致；Secret 创建 201、元数据读取通过。唯一一次 dispatch 为 200，[任务 40627711899](https://github.com/frewily/rain-client-s0-target-20261027/actions/runs/40627711899) 实际成功，Runner 内合成 Secret 校验通过。Secret 删除 204，工作流／配置文件删除均为 200，随后逐项回读为不存在。[成功轮原始脱敏记录](verification/client-s0-github-manager-attempt3.json)。

用户撤销成功轮令牌后，程序自动检查同一令牌返回 401、丢弃持有值并正常退出。临时环境 `/private/tmp/rain-client-s0/github-manager-venv` 已删除。独立所有者身份只读回查确认：文件树与原基线相同，Actions 策略与原值相同；target 累计 3 次成功运行，control 为 0。本轮管理验证共新增 1 次任务，前两次失败尝试和参数对照均为 0 次。

首轮独立撤销 401、第二轮仅用户报告撤销、成功轮独立撤销 401，分别保留；没有将第二轮的证据补写为独立核验。App 注册、仅安装 target 的配置、两个原空测试仓库及正常提交／运行历史保留。

本轮结束。下一切片是 Cloudflare 的账号发现及自动部署权限验证，需要另列精确 scope 和测试资源。自动 Fork、跨账号公开授权、长期凭据持久化、Flutter／Android 和业务课堂验证不在本轮通过范围内。
