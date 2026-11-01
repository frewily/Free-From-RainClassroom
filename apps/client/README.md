# 雨课堂管理客户端（开发验证版）

当前版本 0.3.4：安卓雨课堂登录和 GitHub 绑定已获用户验收；Cloudflare 官方授权、应用部署合成 Worker／测试工作流、实际空任务成功、手机结果展示和关闭公网入口已完成真机验证。113 项本地测试通过。手机直连测试地址仍有限制，部署结果由云端任务严格核验。当前只使用原本人账号与空测试仓库，真实课表／课堂、Mac Flutter、自动 Fork、公开跨账号发行和长期调度另行接入。详见[最新实测与修复](../../docs/client-app-android-callback-fix.md)。

当前实现安卓官方网页登录、本机 Cookie 提取、独立只读会话验证、安全保存、重开检查和本机退出。开发应用 ID 为 `top.frewily.rainclient.dev`，与此前环境验证包分开；Mac 工程保留，尚未在本轮构建验收。

0.2.0 新增底部 GitHub 入口：复用既有私有管理测试应用完成设备授权、账号及已授权仓库识别、独立本机加密保存、恢复、仓库选择和清除。此连接模块没有仓库／Secrets／Actions 写接口，后续写操作由独立部署模块处理。授权信息与雨课堂分开；实际手机验证和本轮证据见[GitHub 功能验收](../../docs/client-app-github-binding.md)。

0.3.0 在同一包中接通 Cloudflare 官方 PKCE 授权、手机回调、安全保存及测试部署与结果查看。GitHub 连接模块保持只读；新增部署模块只在用户确认后对原空测试仓库的单份随机工作流及本次随机 Worker 操作，每份计划最多一次派发，不操作生产资源或 Secrets。[整段功能验收](../../docs/client-app-test-deployment.md)包含具体写入范围和手机操作。原版的 98 项本地测试、生成源码语法和开发包核验通过；真机返回和云端整链路在 0.3.4 完成修复及实际验证。

## 用户流程

1. 进入应用后先检查本机保存能力，显示“还未登录”。
2. 点击“前往官方登录”，在雨课堂官方页面正常操作。只有官网确需打开微信时才由用户确认跳转。
3. 完成后点击“我已完成登录，检查状态”。只读接口确认会话有效且安全保存成功后，首页显示“已登录”。
4. 重开时重新检查保存会话。断网或无法判断时保留记录；仅明确失效时请求重新登录。
5. “退出本机登录”清除本机记录和本应用登录容器 Cookie，云端监听启停另作独立操作。

同一手机的官方登录、微信返回、真实 Keystore 保存及重开需要真机验收。系统浏览器显示已登录不能证明本应用能取得它的 Cookie；本应用不会读取其他应用或系统浏览器的 Cookie，也不提供粘贴或导出会话入口。

## 本地开发

已核对工具为 Flutter 3.47.8、Dart 3.13.7、Java 17、Android SDK 36／Build-Tools 36.0.0／NDK 28.2.13676358。保持依赖锁文件，现有工具可以供其他项目复用。

```sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub
```

当前 Release 编译仍使用开发签名和开发应用 ID，用于本轮验证；正式发布签名另行准备。项目限定复用现有 SDK，关闭构建时自动追加 SDK。`jni`／`jni_flutter` 默认编译 API 35；本工程通过本地 `finalizeDsl` 配置使用已安装 API 36 编译这两个库的源码，不修改插件缓存、最低运行版本或其他项目。

本机特有的工具选择、代理和缓存配置放在仓库外，不写入共享源码。出现 Google Maven 404 时先对照真实连接路径，不通过降级版本或关闭 TLS 校验处理。

JNI 的原生构建还需要 CMake（≥3.10）和 Ninja。本机已找到 REA 工具环境中的 CMake 3.31.6／Ninja 1.11.1，无新增安装；通过忽略的 `android/local.properties` 设置现有 `cmake.dir`，并在隔离 Gradle 配置中设置 `rainclient.cmakeVersion=3.31.6`、将已有 Ninja 加入本次进程 PATH。源码不固定这些机器路径。其他机器可使用已安装 SDK CMake 或按自身路径配置，缺少时先说明安装范围。

ARM64 交付采用 `--split-per-abi`，以免第三方 AAR 额外携带其他 ABI 的原生库。此模式生成 `app-arm64-v8a-release.apk`，实际包名、版本号、架构和签名以构件核验记录为准。

## 代码阅读顺序

- `lib/auth/session_controller.dart`：先看 `_loadSaved` 的有效／明确失效／暂不可用三个分支，再看退出与操作序号。
- `lib/auth/session_client.dart`：固定只读接口、响应判据、超时及响应大小上限。
- `lib/auth/session_store.dart`：本机安全存储及保存、删除后的回读检查。
- `lib/auth/cookie_reader.dart`、`session_cookie.dart`：读取当前容器会话，保留值里的等号；原生桥接仅允许固定 HTTPS 站点。
- `lib/login_page.dart`：页面与按钮如何触发上述状态变化。

测试使用合成会话，覆盖网络失败保留旧记录、过期清除、取消恢复、保存失败、退出与晚到验证／读取／写入之间的交错。不要把自动测试通过当成真实账号流程已经通过。

会话、授权码、原始个人信息响应不进入日志、仓库或云端。官方网页会按正常流程加载自身页面和资源；本应用单独发起的登录检查只使用雨课堂 `userinfo` 只读接口。

GitHub 代码位于 `lib/github/`：`github_client.dart` 限定官方授权与只读接口，`github_controller.dart` 处理授权／恢复／退出，`github_store.dart` 使用独立安全存储，`github_page.dart` 提供操作界面。更新凭据先记录进行中标记；结果不明时要求重新授权，避免重放可能已失效的旧凭据。该本机逻辑的合成测试不代表 Worker 长期调度或真实凭据更新已经验收。
