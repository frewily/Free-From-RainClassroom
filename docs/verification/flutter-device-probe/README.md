# Flutter 环境验证程序的源码快照

这是阶段 0 的临时程序，不是正式客户端。只显示本地合成状态，验证首帧、按钮计数与重新创建后的状态重置，没有账号、课表或云端调用。

2026-10-28 已通过 Flutter 静态分析和 1 项界面行为测试。安卓 APK 构建及真机结果以[执行记录](../client-s0-flutter-device-runtime.json)为准，不由源码快照推断。

## 重建方式

1. 使用官方 Flutter `3.47.8` 标签，提交必须为 `737ba8f885dc774b53b442759999a312c9461e4e`；Dart 为 3.13.7。
2. 在新的空目录生成临时工程：

   ```sh
   flutter create --empty --no-pub --platforms=android,macos --project-name probe --org top.frewily.rainclient <空目录>
   ```

3. 将本目录内 `source-manifest.json` 列出的相对路径复制到该工程，核对摘要；不复制 README 或清单本身。
4. 依赖固定到 `pubspec.lock`，使用独立缓存和已列明的 SDK 组件。Gradle 9.3.1 使用同版本 bin 分发及官方 SHA-256，不下载其文档源码；不自动追加未准备好的 SDK。
5. 执行 `flutter pub get`、`flutter analyze --no-pub`、`flutter test --no-pub --reporter expanded`、`flutter build apk --debug --no-pub`。

手机包名为 `top.frewily.rainclient.probe`。截图、手机实际操作和 Mac 构建分别验收，debug 签名不能作为正式发布签名。

测试所用通用路径为 `/Users/frewily/Library/Developer/flutter/3.47.8` 和 `/Users/frewily/Library/Android/sdk`；仅本轮进程通过 `/Users/frewily/Library/Caches/RainClient/env.zsh` 选择工具及隔离缓存，没有修改终端启动文件。

本机 Java 默认经过系统代理访问 Google Maven 返回 404，同一官方文件直连为 200。已在本轮独立 `GRADLE_USER_HOME/gradle.properties` 设置 Google 主机直连并验证，不将本机代理地址写入可复用源码快照。其他机器应按自己的连接情况配置。
