import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'deployment_controller.dart';
import 'deployment_model.dart';

class DeploymentPage extends StatefulWidget {
  const DeploymentPage({super.key, required this.controller});
  final DeploymentController controller;
  @override
  State<DeploymentPage> createState() => _DeploymentPageState();
}

class _DeploymentPageState extends State<DeploymentPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.restore());
    });
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认执行'),
            ),
          ],
        ),
      ) ??
      false;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller, r = c.record;
      return Scaffold(
        appBar: AppBar(title: const Text('部署验证')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  c.successful
                      ? Icons.check_circle_outline
                      : Icons.rocket_launch_outlined,
                  size: 42,
                  color: const Color(0xff28685e),
                ),
                const SizedBox(height: 20),
                Text(
                  c.successful ? '测试链路已跑通' : '连接部署与运行结果',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                Text(c.message, style: const TextStyle(height: 1.7)),
                const SizedBox(height: 20),
                if (c.busy) const LinearProgressIndicator(),
                if (r == null || r.cleaned)
                  FilledButton(
                    onPressed: c.busy ? null : c.prepare,
                    child: const Text('检查并生成测试部署清单'),
                  ),
                if (r != null && !r.cleaned) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('本次测试清单'),
                          const SizedBox(height: 12),
                          Text(
                            'Worker：${r.plan.worker}\n仓库：$deploymentRepository\n工作流：${r.plan.filename}',
                            style: const TextStyle(height: 1.6),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '新建一个仅返回合成状态的 Worker 和一份空工作流，最多提交一次空任务。测试入口在任务结束或清理时关闭。不会使用真实课表、课堂凭据或付费配置。',
                            style: TextStyle(fontSize: 12, height: 1.6),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: c.busy
                        ? null
                        : () async {
                            if (!r.dispatchAttempt &&
                                !await _confirm(
                                  '部署并运行本次测试？',
                                  '将在原本人 Cloudflare 账号部署 ${r.plan.worker}，临时开放其合成状态入口。\n\n'
                                      '在 $deploymentRepository 写入 ${r.plan.workflow}，并最多触发一次空任务，由它读取此入口。\n\n'
                                      '将产生正常的仓库提交及运行历史。任务结束后关闭公网入口，资源与文件保留，可用下方按钮清理。此操作不参与真实课堂。',
                                )) {
                              return;
                            }
                            await c.deploy();
                          },
                    child: Text(r.dispatchAttempt ? '继续检查任务结果' : '确认部署并运行空任务'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: c.busy
                        ? null
                        : () async {
                            if (await _confirm(
                              '清理本次测试？',
                              '关闭本次 Worker 入口并清空绑定，保留空 Worker；删除本次未被外部改动的测试工作流文件。Git 提交及运行历史保留。其他资源保持原样。',
                            )) {
                              await c.cleanup();
                            }
                          },
                    child: const Text('清理本次测试'),
                  ),
                  if (r.runId != null)
                    TextButton(
                      onPressed: () => launchUrl(
                        Uri.parse(
                          'https://github.com/$deploymentRepository/actions/runs/${r.runId}',
                        ),
                        mode: LaunchMode.externalApplication,
                      ),
                      child: const Text('在 GitHub 查看本次任务'),
                    ),
                  if (r.runId != null)
                    Text(
                      '任务：${r.runId}\n状态：${r.runStatus}\n结果：${r.conclusion ?? '等待结果'}',
                      style: const TextStyle(height: 1.7),
                    ),
                  if (r.phoneHealthReachable == false)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        '手机直连暂未通过；部署结果以云端空任务的严格核验为准。',
                        style: TextStyle(fontSize: 12, height: 1.6),
                      ),
                    ),
                ],
                const SizedBox(height: 24),
                for (final event in c.events.reversed.take(8))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '· $event',
                      style: const TextStyle(fontSize: 12, height: 1.5),
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
