# 阶段 0：Flutter 与安卓真机最小验证及安装方案

日期：2026-10-28。状态：通用目录安装与 Android APK 构建已通过。Flutter／Dart、五项 Android 组件、静态分析、1 项界面测试、APK 包名及签名均已核验，Flutter doctor 的 Android toolchain 通过。主人随后反馈点击计数与退出重开归零正常；尚未独立连接设备或核对设备信息。完整 Xcode 仍未安装，Mac 构建待验证。本轮不修改监听代码或生产资源。实际进展见[执行记录](verification/client-s0-flutter-device-runtime.json)。

## 1. 本轮目标和先后顺序

主人已确认有可通过 USB 连接的安卓手机。先做安卓真机验证，省去 Android Studio、模拟器和系统镜像；Mac 仍为首版目标，完整 Xcode 准备好后单独验收。

第一切片只验证固定工具链能编译一个 Flutter 测试程序，并在主人选定的手机显示首帧、响应按钮、退出再打开。程序只显示本地合成状态，不包含个人课表、凭据、登录或云端操作。安装环境与这个可见结果通过后，再做内嵌雨课堂登录、授权返回与安全存储，避免将 SDK 可用误作登录能力通过。

## 2. 本机实际预检

| 项目 | 2026-10-28 观察结果 |
| --- | --- |
| Mac | Apple Silicon／arm64，macOS 27.0.1，约 232 GiB 可用空间 |
| Apple 开发工具 | 已有 Command Line Tools 和 macOS SDK；当前选择 `/Library/Developer/CommandLineTools`。标准位置没有完整 Xcode，`xcodebuild`／`simctl` 不可用 |
| Flutter／Dart | 当前 PATH 和本轮检查的常见位置均未发现；没有穷尽搜索整块磁盘 |
| Android | 当前没有 adb、sdkmanager、emulator；标准 SDK 和 Android Studio 目录不存在 |
| Java | 已有 Homebrew Java 17.0.15 和 Java 23.0.2。当前 PATH 的 java 为 17，但系统 Java Home 查询指向 Corretto 8，运行时必须显式选定 |
| 已有用户缓存 | `.gradle`、`.android` 已存在，可能被其他项目使用。本轮保留它们，使用独立缓存和调试配置 |
| 真机 | 主人报告可用且可 USB 连接；系统版本、CPU 架构、连接及 USB 调试尚未验证 |

完整脱敏预检和资料摘要见 [预检证据](verification/client-s0-flutter-device-preflight.json)。这些是本机环境事实及官方资料核对，不是 Flutter 编译或真机验收结果。

## 3. 已批准的安卓工具范围

固定下载官方稳定版本，不随 `latest` 自动升级。下面的 NDK 已计入空间预算；不会在构建时悄悄追加其他版本。

| 组件 | 固定候选版本／来源 | 下载量与用途 |
| --- | --- | --- |
| Flutter＋内含 Dart | Flutter 3.47.8 stable、Dart 3.13.7，ARM64；Google 官方 Flutter 存储 | SDK 压缩包 2,267,355,570 字节，约 2.27 GB；生成工程、编译、分析和运行 |
| Android Command-line Tools | 22.0，`commandlinetools-mac_arm64-15859902_latest.zip`；Android 官方下载页 | 156,083,281 字节，约 156 MB；固定编号，不使用清单中另一个更新的 latest 别名 |
| Android Platform-Tools | 37.0.1；Google SDK 仓库 | 约 16 MB；与选定手机通信、安装和启动本轮测试包 |
| Android Platform | API 36，revision 2；Google SDK 仓库 | 约 66 MB；与 Flutter 固定模板的 compile／target SDK 对齐 |
| Android Build-Tools | 36.0.0；Google SDK 仓库 | 约 79 MB；生成测试 APK |
| Android NDK | 28.2.13676358／r28c；Google SDK 仓库 | 约 952 MB；与 Flutter 模板及 AGP 默认值一致 |
| Gradle 及 Android 编译依赖 | Gradle 9.3.1、AGP 9.1.0、Kotlin 插件 2.4.0，按固定 Flutter 提交模板 | 来自 Gradle 官方分发、Google Maven、Maven Central，下载量依实际依赖解析记录 |
| Flutter 基础开发依赖 | `flutter`／`flutter_test` 来自 SDK；模板 `flutter_lints` 固定为 6.0.0，传递依赖记录到 lockfile | 使用 pub.dev；本切片不增加 WebView、登录或安全存储插件 |
| Java | 复用 `/opt/homebrew/opt/openjdk@17`，必要时工具管理命令复用现有 Java 23 | 不安装 Java，不修改默认 JDK；AGP 9.1 官方最低要求为 Java 17，Command-line Tools 的实际 Java 要求待运行检查 |

官方 Flutter 版本清单中的 SHA-256：

```text
Flutter ARM64 3.47.8:
6114edc2dae3636cfefb7e4456a4510399ee856e324149b34dbacb509e329d05

Android Command-line Tools ARM64 22.0:
835b62a26162b229b441d1f6d4680383815a270809eb33522c0d480fa5002c4e
```

下载后先核验这些摘要，再解压或运行。其他 Android 包对照官方组件清单的校验值，记录实际安装 revision。若构建要求额外 SDK、CMake、模拟器、CocoaPods、Rosetta 或其他版本，先记录原因和新增范围，不自动扩大安装。

实际执行中完整 Flutter 压缩包下载超时，因此改用同一官方仓库的 `3.47.8` 标签安装，核对提交仍为 `737ba8f885dc774b53b442759999a312c9461e4e`。实际 CLI 确认 Flutter 3.47.8、Dart 3.13.7、engine `cf636b1dfb818dd6a3ff16e390e93b1a036969c8`；没有更换版本。完整 Flutter ZIP 没有下载完成，不能记为其 SHA-256 已核验。独立下载的同一 Dart 组件按官方对象大小／MD5 核验，官方首次启动随后也成功安装该固定组件并生成工具缓存。标签检出处于 detached HEAD，CLI 显示 `[user-branch]`，不将其冒充已经切换到可自动升级的 stable 分支。

Flutter 官方版本索引已经改到 `flutter_infra_release/releases/releases_macos.json`；旧的 `flutter/releases/` 路径返回 404。本轮从官方下载页实际使用的公开脚本确认新地址。另发现本机代理访问 Android 下载地址和组件清单返回 404，而同一官方地址直接连接成功；后续针对这些官方下载使用进程级直接连接，不修改系统代理或换第三方下载镜像。

初次下载合计预计约 4–6 GB，含构建依赖及引擎补充缓存；解压、构建和保留下载包的峰值建议预留 **20–25 GB**。Flutter 和 Android 固定压缩包体积已经查询，其余是预算，不是实测占用或下载承诺。安装后记录实际新增空间，不将安装速度写成保证。

## 4. 文件与环境修改清单

原草案拟将工具和缓存都放在 RainClient 目录。主人希望以后其他应用也能共用，已明确批准改用以下通用安装目录；缓存仍按本轮用途隔离：

```text
/Users/frewily/Library/Developer/flutter/3.47.8/  Flutter SDK 及引擎缓存
/Users/frewily/Library/Android/sdk/              Android 工具、API、Build-Tools 和固定 NDK
/Users/frewily/Library/Caches/RainClient/
  downloads/            待核验下载包
  pub-cache/            本轮 Dart 基础依赖
  gradle-home/          本轮 Gradle 分发与依赖缓存
  android-user-home/    本轮 adb 调试配置和 debug keystore
  xdg-config/          可重定向的工具配置
```

通过本轮进程的 PATH、JAVA_HOME、ANDROID_HOME、ANDROID_USER_HOME、GRADLE_USER_HOME、PUB_CACHE、XDG_CONFIG_HOME 等配置指向上述目录；不改 shell 启动文件、全局 Java、系统代理和已有项目配置。先关闭 Flutter／Dart 的可选使用统计；实际命令若仍写入不能重定向的用户级文件，先记录文件及用途，不覆盖旧文件。保留系统 HOME 的正常含义。

临时工程位于 `/private/tmp/rain-client-s0/flutter-device-probe/`，只创建 Android／macOS 两个平台。生成工程时先不解析依赖，审阅并固定模板开发依赖后再下载。测试包名为 **`top.frewily.rainclient.probe`**，界面名为“雨课堂客户端 · 环境验证”；不用正式应用身份或正式发布密钥。如果手机已存在相同包名，先检查归属和签名，不覆盖未知安装。

需要主人亲自完成的步骤：按官方提示阅读并确认 Android SDK 许可证；在选定手机开启开发者选项和 USB 调试、确认这台电脑的连接。只对指定设备安装／启动上述测试 APK，不读取相册、联系人或应用数据。连接结果不保存原始设备序列号。

本轮记录源码、固定版本、构建结果和脱敏运行证据，保留工具链供后续使用；临时工程、APK、调试签名和缓存按用途清点，不把 debug keystore 放入仓库。没有 Git 提交、推送、生产部署或真实授权。

## 5. Mac 单独需要完整 Xcode

Flutter Mac 编译需要完整 Xcode；已有 Command Line Tools 能编译此前的原生验证程序，但不等于 Flutter Mac 环境已具备。

官方兼容表当前列有稳定版 Xcode 27.1，支持 macOS 26.6 及以后；本机系统满足该版本的声明范围。拟由主人从 Mac App Store／Apple Developer 官方来源安装到 `/Applications/Xcode.app`，首次启动及协议由主人亲自完成。仅为本轮 macOS 构建准备，不选择额外 iOS／watchOS／visionOS 模拟器镜像。建议另预留约 **20–35 GB**，具体以官方安装器和实际占用为准。

本轮不全局切换 `xcode-select`。Xcode 就绪后通过进程级 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 检查和编译；如果首次组件准备需要管理员操作，按具体提示交给主人完成。

Flutter 3.47 的 Swift Package Manager 已默认启用，空工程先沿用它，不额外安装 CocoaPods。后续选择登录或存储插件时先核对 Mac／Android 支持、最低系统和 SwiftPM 兼容性，不能据此承诺所有插件都无需 CocoaPods。无 Developer ID 不阻止先做本机调试；发布签名、公证和下载后的安装仍需独立验收。

## 6. 批准后的执行和验收

1. 创建独立目录，下载固定官方压缩包并核验，记录版本和空间；配置进程级 Java、缓存及下载网络，不更改现有项目。
2. 由主人确认必要的官方许可证后安装已列组件。运行版本检查和 Flutter doctor，区分安卓就绪与 Mac／其他未选平台缺项。
3. 在临时目录生成最小工程，固定依赖和 lockfile；界面只有本地验证状态、一个可响应的按钮，不连接云端或个人账号。
4. 完成静态分析、必要的界面行为测试和 Android debug APK 构建。工具通过、APK 构建通过分别记录。
5. 主人连接并确认手机后，只检查必要的系统版本／CPU 架构／调试状态，选择该设备安装并启动测试包。记录实际首帧、按钮响应、关闭重开；ADB 安装成功不等于界面验收通过。
6. Mac 等 Xcode 独立准备好后，用同一工程编译运行，记录窗口、按钮和重开结果。安卓通过不填补 Mac 结果。
7. 汇总环境、构建、真机、Mac 和未验证项。本切片完成后再准备登录容器、回调和安全存储；不在没有额外范围说明时顺带安装插件或改云端回调。

手机版本或架构不符合模板时先报告，不静默提高最低版本或替换测试设备。工具版本或官方校验值不匹配、额外安装要求、源码已有未知内容时停止对应动作，保留可诊断证据。

## 7. 本轮执行与验收结果

- 已安装：Flutter 3.47.8／Dart 3.13.7；Android Command-line Tools 22.0、Platform-Tools 37.0.1、API 36 revision 2、Build-Tools 36.0.0、NDK 28.2.13676358。SDK Manager 正确列出全部五项组件，NDK host 工具包含 arm64，不需要为本切片安装 Rosetta。
- NDK 首次通过 SDK Manager 安装时出现 ZIP 读取错误；失败文件未保留，不能精确断言原因。重新单独下载后，952,495,160 字节及官方 SHA-1 一致，解压和版本检查通过。手动解压的 NDK／命令行工具按官方 revision 登记；首次本地登记使用旧通用类型格式未被解析，改用当前 SDK 已生成的 generic/02 格式后，回读没有损坏登记警告。
- Java 默认经系统代理访问 Google Maven 的固定插件文件返回 404，同一文件直连为 200。进程级对照确认 Google 非代理主机配置能使 Java 返回 200；修复仅放在本轮独立 Gradle 配置，随后成功解析原定依赖。没有降级 AGP、Kotlin 或 Gradle。
- 静态分析零问题，1 项界面测试通过；实际 Android debug APK 构建成功，签名验证通过。包名为 `top.frewily.rainclient.probe`，标签“雨课堂客户端 · 环境验证”，最低 API 24、目标 API 36，包含 arm64-v8a／armeabi-v7a／x86_64。它是本地合成验证程序，不是正式客户端。
- 测试 APK：`/private/tmp/rain-client-s0/flutter-device-probe/build/app/outputs/flutter-apk/app-debug.apk`，约 143.4 MiB。可审阅的文本源码、依赖锁和配置见[源码快照](verification/flutter-device-probe/README.md)，摘要与构建证据对应。
- 本轮实测目录占用合计约 10.77 GiB，包含工具、保留下载包、独立缓存和临时工程；不是正式应用安装体积。debug keystore 位于独立 Android 用户目录，没有生成正式发布密钥。原 `.android`／`.gradle` 根目录修改时间仍为预检时的 2026-07-20，未创建用户根目录 `.flutter_settings`／`.dart-tool`。
- Flutter doctor 的 Android toolchain 和所需许可证检查通过；固定标签、缺少 Xcode／CocoaPods、进程代理未包含 IPv6 loopback 的提示单独保留，没有为消除提示追加安装或改变系统配置。构建有 SDK XML 版本提示，但实际打包成功。
- 初次构建结束时手机未连接；随后主人报告测试包点击计数、退出重开归零均正常。未由代理独立安装或连接设备，人工反馈与自动界面测试分别保存。Mac 编译、登录容器、授权返回、安全存储、发布签名和真实课堂仍待验证。未提交／推送 Git。

复用工具时可在当前终端加载 `/Users/frewily/Library/Caches/RainClient/env.zsh`，或者在 IDE 选择上述 Flutter／Android SDK 路径；不会因目录名称而绑定某个项目。没有修改终端启动文件或全局 Java。

## 8. 官方依据

- [Flutter SDK archive](https://docs.flutter.dev/install/archive)及[当前 macOS 版本索引](https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json)。
- [Flutter macOS 环境要求](https://docs.flutter.dev/platform-integration/macos/setup)。
- [Flutter Android 环境与真机设置](https://docs.flutter.dev/platform-integration/android/setup)。
- [Flutter Swift Package Manager](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)。
- [固定 Flutter 提交的 Android 工具版本](https://github.com/flutter/flutter/blob/737ba8f885dc774b53b442759999a312c9461e4e/packages/flutter_tools/lib/src/android/gradle_utils.dart)和[Android 模板默认参数](https://github.com/flutter/flutter/blob/737ba8f885dc774b53b442759999a312c9461e4e/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt)。
- [Android 官方命令行工具](https://developer.android.com/studio#command-line-tools-only)、[组件清单](https://dl.google.com/android/repository/repository2-1.xml)和[AGP 9.1 兼容要求](https://developer.android.com/build/releases/agp-9-1-0-release-notes)。
- [Apple Xcode 兼容表](https://developer.apple.com/support/xcode/)。

公开资料原文暂存 `/private/tmp/rain-client-s0/client-environment-research/`，SHA-256 保存在预检证据中。公开资料、准备计划、安装执行和设备运行分别记录，不提前填为通过。
