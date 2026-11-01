import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'github_client.dart';
import 'github_controller.dart';
import 'github_models.dart';
import 'github_store.dart';

class GithubPage extends StatefulWidget {
  const GithubPage({super.key, this.controller, this.openOfficialPage});
  final GithubController? controller;
  final Future<bool> Function(Uri)? openOfficialPage;

  @override
  State<GithubPage> createState() => _GithubPageState();
}

class _GithubPageState extends State<GithubPage> {
  late final GithubController _connection;
  String? _openError;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _connection =
        widget.controller ??
        GithubController(client: GithubClient(), store: SecureGithubStore());
    unawaited(_connection.restore());
  }

  Future<void> _openOfficial() async {
    final code = _connection.userCode;
    if (code == null || _opening) return;
    setState(() {
      _opening = true;
      _openError = null;
    });
    try {
      await Clipboard.setData(ClipboardData(text: code));
      if (!mounted || !_connection.waiting || _connection.userCode != code) {
        return;
      }
      final open = widget.openOfficialPage;
      final opened = open == null
          ? await launchUrl(
              GithubAppConfig.verificationUri,
              mode: LaunchMode.externalApplication,
            )
          : await open(GithubAppConfig.verificationUri);
      if (!opened && mounted && _connection.userCode == code) {
        setState(
          () =>
              _openError = '未能打开官方页面，可在浏览器访问 github.com/login/device 并输入上面的代码。',
        );
      }
    } on Object {
      if (mounted && _connection.userCode == code) {
        setState(
          () => _openError =
              '暂时无法复制或打开页面，请在浏览器访问 github.com/login/device，手动输入上面的代码。',
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _disconnect() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除本机 GitHub 连接？'),
        content: const Text('这会清除本机保存的授权和仓库选择。GitHub 官网授权及云端运行需单独管理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留连接'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除本机连接'),
          ),
        ],
      ),
    );
    if (approved == true && mounted) await _connection.disconnect();
  }

  @override
  void dispose() {
    if (widget.controller == null) _connection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _connection,
    builder: (context, _) {
      final phase = _connection.phase;
      final connected = phase == GithubPhase.connected;
      final account = _connection.account;
      final code = _connection.userCode;
      final retry = [
        GithubPhase.unavailable,
        GithubPhase.error,
      ].contains(phase);
      final status = switch (phase) {
        GithubPhase.preparing => '正在准备',
        GithubPhase.unbound => '尚未连接',
        GithubPhase.requesting => '正在申请授权',
        GithubPhase.awaitingAuthorization => '等待官方授权',
        GithubPhase.checking => '正在检查',
        GithubPhase.connected => '账号已连接',
        GithubPhase.unavailable => '连接状态待确认',
        GithubPhase.needsAuthorization => '需要重新授权',
        GithubPhase.error => '操作尚未完成',
      };
      return Scaffold(
        appBar: AppBar(title: const Text('GitHub 连接')),
        body: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.account_tree_outlined,
                      size: 36,
                      color: Color(0xff28685e),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      status,
                      key: const ValueKey('github-status'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _connection.message,
                      style: const TextStyle(height: 1.6),
                    ),
                    if (_connection.busy) ...[
                      const SizedBox(height: 20),
                      const LinearProgressIndicator(),
                    ],
                    const SizedBox(height: 24),
                    if (code != null) _authorizationCard(code),
                    if (connected && account != null) ...[
                      Text(
                        '@${account.login}',
                        key: const ValueKey('github-account'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 18),
                      const Text('已授权仓库'),
                      const SizedBox(height: 8),
                      if (account.repositories.isEmpty)
                        const Text(
                          '尚未找到可访问的仓库。可在 GitHub 的应用安装设置中核对仓库选择，再回来刷新。',
                        ),
                      for (final repo in account.repositories)
                        Card(
                          child: ListTile(
                            key: ValueKey('github-repository-${repo.id}'),
                            leading: Icon(
                              _connection.selectedRepositoryId == repo.id
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                            ),
                            title: Text(repo.fullName),
                            subtitle: Text(
                              repo.archived
                                  ? '已归档，暂不可选择'
                                  : '${repo.isPrivate ? '私有' : '公开'}仓库 · 仅保存本机选择',
                            ),
                            onTap: repo.archived
                                ? null
                                : () => _connection.selectRepository(repo.id),
                          ),
                        ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _connection.restore,
                        icon: const Icon(Icons.refresh),
                        label: const Text('刷新账号与仓库'),
                      ),
                    ],
                    if (retry)
                      OutlinedButton.icon(
                        onPressed: _connection.retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试连接'),
                      ),
                    if (!connected &&
                        !_connection.waiting &&
                        !_connection.busy) ...[
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        key: const ValueKey('github-authorize'),
                        onPressed: _connection.canAuthorize
                            ? () {
                                setState(() => _openError = null);
                                unawaited(_connection.authorize());
                              }
                            : null,
                        icon: const Icon(Icons.link),
                        label: Text(
                          phase == GithubPhase.unbound ? '绑定 GitHub' : '重新授权',
                        ),
                      ),
                    ],
                    if (_connection.waiting || phase == GithubPhase.requesting)
                      TextButton(
                        onPressed: _connection.cancelAuthorization,
                        child: const Text('取消本次授权等待'),
                      ),
                    if ((_connection.hasSavedConnection ||
                            phase == GithubPhase.error) &&
                        !_connection.waiting)
                      TextButton(
                        key: const ValueKey('github-disconnect'),
                        onPressed: _disconnect,
                        child: const Text('清除本机 GitHub 连接'),
                      ),
                    const SizedBox(height: 28),
                    Text(
                      '开发验证应用：${_connection.config.name}\n'
                      '当前仅供 ${_connection.config.owner} 账号验证，使用此前选定仓库的授权。'
                      '应用本身具有仓库管理权限，本步骤只读取账号及已授权仓库；'
                      '连接信息加密保存在本机，不修改仓库或触发任务。',
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.7,
                        color: Color(0xff61726b),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _authorizationCard(String code) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('一次性授权代码'),
          const SizedBox(height: 12),
          SelectableText(
            code,
            key: const ValueKey('github-user-code'),
            style: const TextStyle(
              fontSize: 30,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Text('在 GitHub 官方页输入代码，核对应用名为\n${_connection.config.name}，完成后返回应用。'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _opening || !_connection.waiting ? null : _openOfficial,
            icon: const Icon(Icons.open_in_new),
            label: const Text('复制代码并打开 GitHub'),
          ),
          if (_openError != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _openError!,
                style: const TextStyle(color: Color(0xff9b3c32)),
              ),
            ),
          const SizedBox(height: 10),
          const Text(
            '代码仅用于这一次官方授权，过期后可重新申请。无需复制或发送任何令牌。',
            style: TextStyle(fontSize: 12, height: 1.6),
          ),
        ],
      ),
    ),
  );
}
