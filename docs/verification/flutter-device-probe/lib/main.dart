import 'package:flutter/material.dart';

void main() => runApp(const EnvironmentProbe());

class EnvironmentProbe extends StatelessWidget {
  const EnvironmentProbe({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '雨课堂客户端 · 环境验证',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorSchemeSeed: const Color(0xFF245D78),
      useMaterial3: true,
    ),
    home: const ProbePage(),
  );
}

class ProbePage extends StatefulWidget {
  const ProbePage({super.key});

  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  int taps = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('环境验证')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.check_circle_outline, size: 56),
                const SizedBox(height: 20),
                Text(
                  '测试程序已打开',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                const Text(
                  '这个页面只验证显示和按钮操作。\n当前没有绑定账号，也没有启用课程监听。',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                FilledButton(
                  key: const ValueKey('probe-button'),
                  onPressed: () => setState(() => taps++),
                  child: const Text('测试按钮'),
                ),
                const SizedBox(height: 12),
                Text('按钮已响应 $taps 次', key: const ValueKey('tap-count')),
                const SizedBox(height: 28),
                const Text('S0 · 仅含本地合成状态'),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
