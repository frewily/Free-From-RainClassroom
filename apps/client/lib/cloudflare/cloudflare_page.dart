import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'cloudflare_auth.dart';
import 'cloudflare_controller.dart';

class CloudPage extends StatefulWidget {
  const CloudPage({super.key, required this.controller, this.open});
  final CloudController controller;
  final Future<bool> Function(Uri)? open;
  @override
  State<CloudPage> createState() => _CloudPageState();
}

class _CloudPageState extends State<CloudPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.restore());
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      return Scaffold(
        appBar: AppBar(title: const Text('Cloudflare 连接')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.cloud_outlined,
                  size: 40,
                  color: Color(0xff28685e),
                ),
                const SizedBox(height: 24),
                Text(
                  c.phase == CloudPhase.connected
                      ? '账号已连接'
                      : c.phase == CloudPhase.unbound
                      ? '尚未连接'
                      : '连接处理中',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                Text(c.message, style: const TextStyle(height: 1.7)),
                const SizedBox(height: 24),
                if (c.busy) const LinearProgressIndicator(),
                if (c.phase == CloudPhase.connected) ...[
                  Text(
                    c.accountName ?? 'Cloudflare 账号',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton(
                    onPressed: c.restore,
                    child: const Text('刷新账号状态'),
                  ),
                ] else if (!c.busy) ...[
                  FilledButton(
                    onPressed: () => c.authorize(
                      widget.open ??
                          (uri) => launchUrl(
                            uri,
                            mode: LaunchMode.externalApplication,
                          ),
                    ),
                    child: const Text('绑定 Cloudflare'),
                  ),
                  if (c.phase != CloudPhase.unbound)
                    TextButton(onPressed: c.retry, child: const Text('重试连接')),
                ],
                if (c.phase == CloudPhase.authorizing)
                  TextButton(
                    onPressed: c.cancelAuthorization,
                    child: const Text('取消本次授权等待'),
                  ),
                if (c.hasSaved || c.phase == CloudPhase.error)
                  TextButton(
                    onPressed: () async {
                      final yes = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('清除本机 Cloudflare 连接？'),
                          content: const Text('仅清除本机授权。已部署的云端资源和其他连接需分别管理。'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('保留'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('清除本机连接'),
                            ),
                          ],
                        ),
                      );
                      if (yes == true) await c.disconnect();
                    },
                    child: const Text('清除本机 Cloudflare 连接'),
                  ),
                const SizedBox(height: 28),
                const Text(
                  '开发验证应用：${CloudConfig.name}\n'
                  '沿用原本人账号和五项管理权限：Workers Admin、D1、KV 写入及用户、账号只读。'
                  '此处只绑定账号；创建测试 Worker 前会另行展示具体清单，由你点击确认。'
                  '官方授权完成后请返回应用，授权信息独立加密保存在本机。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.7,
                    color: Color(0xff61726b),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
