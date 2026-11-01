import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../client_support.dart';
import 'cloudflare_auth.dart';
import 'native_cloudflare_callback.dart';

enum CloudPhase {
  preparing,
  unbound,
  authorizing,
  checking,
  connected,
  unavailable,
  error,
}

class CloudController extends ChangeNotifier {
  CloudController({
    required this.client,
    required this.store,
    CloudCallback Function()? callbackFactory,
    this.ioTimeout = const Duration(seconds: 8),
  }) : callbackFactory =
           callbackFactory ??
           (() => Platform.isAndroid
               ? NativeCloudCallback()
               : LoopbackCloudCallback());
  final CloudGateway client;
  final RecordStore store;
  final CloudCallback Function() callbackFactory;
  final Duration ioTimeout;
  final _storage = SerialWork();
  CloudSession? _saved;
  CloudSession? _candidate;
  CloudCallback? _callback;
  int _generation = 0;
  bool _disposed = false, _clearPending = false;
  CloudPhase phase = CloudPhase.preparing;
  String message = '正在读取本机 Cloudflare 连接。';
  String? get accountName => _saved?.accountName;
  bool get busy => [
    CloudPhase.preparing,
    CloudPhase.authorizing,
    CloudPhase.checking,
  ].contains(phase);
  bool get hasSaved => _saved != null;
  bool _current(int op) => !_disposed && op == _generation;
  int _begin() {
    _generation++;
    client.cancel();
    final callback = _callback;
    _callback = null;
    if (callback != null) unawaited(callback.close());
    return _generation;
  }

  void _show(CloudPhase value, String text) {
    if (_disposed) return;
    phase = value;
    message = text;
    notifyListeners();
  }

  Future<T> _local<T>(Future<T> future) async {
    try {
      return await future.timeout(ioTimeout);
    } on Object {
      throw const ClientFailure(ClientIssue.storage);
    }
  }

  Future<T> _remote<T>(Future<T> future, int op) => future.timeout(
    const Duration(seconds: 45),
    onTimeout: () {
      if (_current(op)) client.cancel();
      throw const ClientFailure(ClientIssue.network);
    },
  );
  void _failed(Object error) {
    final issue = error is ClientFailure ? error.issue : ClientIssue.response;
    if (issue == ClientIssue.cancelled) return;
    _show(
      issue == ClientIssue.storage ? CloudPhase.error : CloudPhase.unavailable,
      switch (issue) {
        ClientIssue.authorization => '需要重新确认 Cloudflare 授权或账号范围，请重新连接。',
        ClientIssue.storage => '本机保存或清除尚未确认，请重试。',
        ClientIssue.conflict => '本机授权返回通道暂不可用，请关闭其他验证窗口后重试。',
        _ => '暂时无法确认 Cloudflare 连接，已有本机记录已保留，请检查网络后重试。',
      },
    );
  }

  Future<void> restore() async {
    if (_disposed) return;
    if (_clearPending) return disconnect();
    final op = _begin();
    _show(CloudPhase.preparing, '正在检查本机 Cloudflare 连接。');
    try {
      final raw = await _local(_storage.run(store.read));
      if (!_current(op)) return;
      if (raw == null) {
        _saved = null;
        _show(CloudPhase.unbound, '连接后可检查账号，并继续部署测试环境。');
        return;
      }
      final saved = CloudSession.fromJson(raw);
      _saved = saved;
      _show(CloudPhase.checking, '正在确认 Cloudflare 账号。');
      final checked = await _remote(client.inspect(saved), op);
      if (!_current(op)) return;
      _saved = checked;
      _show(CloudPhase.connected, '账号已连接，可以前往“部署验证”检查测试环境。');
    } on Object catch (error) {
      if (_current(op)) _failed(error);
    }
  }

  Future<void> authorize(Future<bool> Function(Uri) open) async {
    if (_disposed || busy || _clearPending) return;
    final op = _begin();
    _candidate = null;
    final callback = callbackFactory();
    _callback = callback;
    // Attach an error consumer before binding or opening the external browser.
    final codeFuture = callback.code;
    unawaited(
      codeFuture.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    _show(CloudPhase.authorizing, '请在 Cloudflare 官方页面确认原测试应用和账号，完成后返回。');
    try {
      final pkce = CloudPkce();
      try {
        await callback.start(pkce);
      } on Object {
        if (!_current(op)) return;
        throw const ClientFailure(ClientIssue.conflict);
      }
      if (!_current(op)) {
        await callback.close();
        return;
      }
      if (!await open(pkce.authorization)) {
        throw const ClientFailure(ClientIssue.response);
      }
      if (!_current(op)) return;
      final code = await codeFuture.timeout(const Duration(minutes: 10));
      if (!_current(op)) return;
      _show(CloudPhase.checking, '已收到官方返回，正在核对授权和账号。');
      final candidate = await _remote(client.exchange(code, pkce), op);
      if (!_current(op)) return;
      _candidate = candidate;
      await _saveCandidate(op);
    } on Object catch (error) {
      if (_current(op)) _failed(error);
    } finally {
      await callback.close();
      if (identical(_callback, callback)) _callback = null;
    }
  }

  Future<void> _saveCandidate(int op) async {
    final checked = await _remote(client.inspect(_candidate!), op);
    if (!_current(op)) return;
    await _local(
      _storage.run(() async {
        if (_current(op)) await store.write(checked.toJson());
      }),
    );
    if (!_current(op)) return;
    _saved = checked;
    _candidate = null;
    _show(CloudPhase.connected, '账号已核对并加密保存在本机，可以继续部署验证。');
  }

  void cancelAuthorization() {
    if (_disposed || phase != CloudPhase.authorizing) return;
    _begin();
    _candidate = null;
    _show(
      _saved == null ? CloudPhase.unbound : CloudPhase.unavailable,
      '已取消本次等待，原本机记录保持原样。',
    );
  }

  Future<void> retry() async {
    if (_disposed || busy) return;
    if (_clearPending) return disconnect();
    if (_candidate == null) return restore();
    final op = _begin();
    _show(CloudPhase.checking, '正在重新核对并保存 Cloudflare 账号。');
    try {
      await _saveCandidate(op);
    } on Object catch (error) {
      if (_current(op)) _failed(error);
    }
  }

  Future<CloudSession> forDeployment() async {
    await restore();
    if (phase != CloudPhase.connected || _saved == null) {
      throw const ClientFailure(ClientIssue.authorization);
    }
    return _saved!;
  }

  Future<void> disconnect() async {
    if (_disposed) return;
    final op = _begin();
    _candidate = null;
    _clearPending = true;
    _show(CloudPhase.checking, '正在清除本机 Cloudflare 连接。');
    try {
      await _local(_storage.run(store.delete));
      if (!_current(op)) return;
      _saved = null;
      _clearPending = false;
      _show(CloudPhase.unbound, '本机连接已清除；已有云端资源和运行需独立管理。');
    } on Object catch (error) {
      if (_current(op)) _failed(error);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _begin();
    _saved = null;
    _candidate = null;
    super.dispose();
  }
}
