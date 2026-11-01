import 'dart:async';

import 'package:flutter/foundation.dart';

import 'github_client.dart';
import 'github_models.dart';
import 'github_store.dart';

enum GithubPhase {
  preparing,
  unbound,
  requesting,
  awaitingAuthorization,
  checking,
  connected,
  unavailable,
  needsAuthorization,
  error,
}

class _StorageQueue {
  Future<void> _tail = Future<void>.value();
  Future<T> run<T>(Future<T> Function() action) {
    final task = _tail.then((_) => action());
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }
}

class GithubController extends ChangeNotifier {
  GithubController({
    required this._client,
    required this._store,
    this.config = const GithubAppConfig(),
    DateTime Function()? now,
    Future<void> Function(Duration)? wait,
    this.ioTimeout = const Duration(seconds: 8),
    this.apiTimeout = const Duration(seconds: 45),
  }) : _now = now ?? DateTime.now,
       _testWait = wait;

  final GithubGateway _client;
  final GithubStore _store;
  final GithubAppConfig config;
  final DateTime Function() _now;
  final Future<void> Function(Duration)? _testWait;
  final Duration ioTimeout;
  final Duration apiTimeout;
  final _storage = _StorageQueue();
  GithubSavedSession? _saved;
  GithubTokens? _candidate;
  GithubDeviceGrant? _grant;
  Timer? _timer;
  Completer<void>? _pause;
  bool _disposed = false;
  bool _disconnectPending = false;
  int _generation = 0;

  GithubPhase phase = GithubPhase.preparing;
  String message = '正在读取本机 GitHub 连接。';
  GithubAccount? account;

  String? get userCode => _grant?.userCode;
  DateTime? get codeExpiresAt => _grant?.expiresAt;
  int? get selectedRepositoryId => _saved?.selectedRepositoryId;
  bool get hasSavedConnection => _saved != null;
  bool get busy => const [
    GithubPhase.preparing,
    GithubPhase.requesting,
    GithubPhase.checking,
  ].contains(phase);
  bool get waiting => phase == GithubPhase.awaitingAuthorization;
  bool get canAuthorize => !busy && !waiting && !_disconnectPending;

  bool _current(int op) => !_disposed && op == _generation;

  int _begin() {
    _generation++;
    _client.cancelPending();
    _timer?.cancel();
    _timer = null;
    final pause = _pause;
    _pause = null;
    if (pause != null && !pause.isCompleted) pause.complete();
    return _generation;
  }

  void _show(GithubPhase next, String text) {
    if (_disposed) return;
    phase = next;
    message = text;
    notifyListeners();
  }

  Future<T> _local<T>(Future<T> task) async {
    try {
      return await task.timeout(ioTimeout);
    } on Object {
      throw const GithubFailure(GithubIssue.storage);
    }
  }

  Future<T> _remote<T>(Future<T> task) {
    final operation = _generation;
    return task.timeout(
      apiTimeout,
      onTimeout: () {
        if (_current(operation)) _client.cancelPending();
        throw const GithubFailure(GithubIssue.timeout);
      },
    );
  }

  Future<bool> _save(GithubSavedSession value, int op) async {
    await _local(
      _storage.run(() async {
        if (_current(op)) await _store.write(value);
      }),
    );
    if (!_current(op)) return false;
    _saved = value;
    return true;
  }

  void _failed(Object error) {
    final issue = error is GithubFailure ? error.issue : GithubIssue.response;
    if (_saved?.refreshPending == true) {
      _show(GithubPhase.needsAuthorization, '上次授权更新没有完整保存，请重新授权；不会重复使用那次更新凭据。');
      return;
    }
    switch (issue) {
      case GithubIssue.unauthorized:
        _show(GithubPhase.needsAuthorization, 'GitHub 连接已失效或被撤销，请重新授权。');
      case GithubIssue.denied:
        _show(
          _saved == null ? GithubPhase.unbound : GithubPhase.unavailable,
          '本次授权未获同意，已有本机连接保持原样。',
        );
      case GithubIssue.expired:
        _show(
          _saved == null ? GithubPhase.unbound : GithubPhase.unavailable,
          '本次一次性代码已过期，可以重新开始授权。',
        );
      case GithubIssue.scope:
        _show(
          GithubPhase.unavailable,
          '当前账号、应用权限或仓库选择与开发版不匹配，请核对 GitHub 的授权范围后重试。',
        );
      case GithubIssue.storage:
        _show(GithubPhase.error, '本机连接保存或清除尚未确认，请重试。');
      case GithubIssue.forbidden:
        _show(GithubPhase.unavailable, 'GitHub 暂时拒绝访问，请检查账号权限或稍后重试，已有记录已保留。');
      case GithubIssue.network:
      case GithubIssue.timeout:
      case GithubIssue.response:
        _show(GithubPhase.unavailable, '暂时无法确认 GitHub 连接，请检查网络后重试，已有记录已保留。');
    }
  }

  Future<void> restore() async {
    if (_disposed) return;
    if (_disconnectPending) return disconnect();
    final op = _begin();
    _grant = null;
    _show(GithubPhase.preparing, '正在检查本机 GitHub 连接。');
    try {
      final value = await _local(_storage.run(_store.read));
      if (!_current(op)) return;
      _saved = value;
      if (value == null) {
        await _local(_storage.run(_store.checkReady));
        if (_current(op)) {
          account = null;
          _show(GithubPhase.unbound, '绑定后可识别账号并选择已授权的仓库。');
        }
        return;
      }
      if (value.appId != config.appId) {
        throw const GithubFailure(GithubIssue.scope);
      }
      if (value.refreshPending) {
        throw const GithubFailure(GithubIssue.unauthorized);
      }
      _show(GithubPhase.checking, '正在确认账号和已授权仓库。');
      var refreshed = false;
      if (!_now()
          .add(const Duration(minutes: 1))
          .isBefore(value.tokens.expiresAt)) {
        if (!await _rotate(op)) return;
        refreshed = true;
      }
      if (!_current(op)) return;
      GithubAccount verified;
      try {
        verified = await _remote(_client.inspect(_saved!.tokens.access));
      } on GithubFailure catch (error) {
        if (!_current(op)) return;
        if (error.issue != GithubIssue.unauthorized || refreshed) rethrow;
        if (!await _rotate(op)) return;
        verified = await _remote(_client.inspect(_saved!.tokens.access));
      }
      if (!_current(op)) return;
      if (verified.id != _saved!.accountId) {
        throw const GithubFailure(GithubIssue.scope);
      }
      final selected = _saved!.selectedRepositoryId;
      if (selected != null &&
          !verified.repositories.any((r) => r.id == selected && !r.archived)) {
        if (!await _save(_copy(_saved!, selected: null), op)) return;
      }
      if (!_current(op)) return;
      account = verified;
      _show(GithubPhase.connected, _connectionMessage());
    } on Object catch (error) {
      if (_current(op)) _failed(error);
    }
  }

  String _connectionMessage() => account!.repositories.isEmpty
      ? '账号已连接，当前没有可访问的已授权仓库；尚未执行部署。'
      : selectedRepositoryId == null
      ? '账号已连接，请选择仓库；当前只读取信息。'
      : '仓库选择已保存在本机；尚未执行部署或启用监听。';

  GithubSavedSession _copy(
    GithubSavedSession value, {
    GithubTokens? tokens,
    bool? pending,
    required int? selected,
  }) => GithubSavedSession(
    appId: value.appId,
    accountId: value.accountId,
    tokens: tokens ?? value.tokens,
    selectedRepositoryId: selected,
    refreshPending: pending ?? value.refreshPending,
  );

  Future<bool> _rotate(int op) async {
    final previous = _saved!;
    if (previous.refreshPending ||
        !_now().isBefore(previous.tokens.refreshExpiresAt)) {
      throw const GithubFailure(GithubIssue.unauthorized);
    }
    // Persist the intent first. A lost response must never replay a rotating
    // refresh token after a restart. Reauthorization is the bounded fallback.
    if (!await _save(
      _copy(previous, pending: true, selected: previous.selectedRepositoryId),
      op,
    )) {
      return false;
    }
    if (!_current(op)) return false;
    final updated = await _remote(_client.refresh(previous.tokens.refresh));
    if (!_current(op)) return false;
    return _save(
      _copy(
        previous,
        tokens: updated,
        pending: false,
        selected: previous.selectedRepositoryId,
      ),
      op,
    );
  }

  Future<void> authorize() async {
    if (_disposed || !canAuthorize) return;
    final op = _begin();
    _candidate = null;
    _grant = null;
    _show(GithubPhase.requesting, '正在向 GitHub 申请一次性授权代码。');
    try {
      await _local(_storage.run(_store.checkReady));
      if (!_current(op)) return;
      final grant = await _remote(_client.startAuthorization());
      if (!_current(op)) return;
      _grant = grant;
      var interval = grant.interval;
      _show(GithubPhase.awaitingAuthorization, '请在 GitHub 官方页面完成授权，再返回应用。');
      while (_current(op) && _now().isBefore(grant.expiresAt)) {
        final remaining = grant.expiresAt.difference(_now());
        await _wait(remaining < interval ? remaining : interval);
        if (!_current(op)) return;
        if (!_now().isBefore(grant.expiresAt)) break;
        GithubPoll result;
        try {
          result = await _remote(_client.poll(grant));
        } on GithubFailure catch (error) {
          if (!_current(op)) return;
          if (![
            GithubIssue.network,
            GithubIssue.timeout,
          ].contains(error.issue)) {
            rethrow;
          }
          final seconds = interval.inSeconds;
          if (seconds < 60) {
            interval = Duration(seconds: (seconds * 2).clamp(5, 60));
          }
          _show(GithubPhase.awaitingAuthorization, '网络暂时未连通，正在等待后重试；仍可取消。');
          continue;
        }
        if (!_current(op)) return;
        if (result.state == GithubPollState.slowDown) {
          interval += const Duration(seconds: 5);
        } else if (result.state == GithubPollState.authorized) {
          final tokens = result.tokens;
          if (tokens == null) throw const GithubFailure(GithubIssue.response);
          _candidate = tokens;
          _grant = null;
          await _completeAuthorization(op);
          return;
        }
      }
      throw const GithubFailure(GithubIssue.expired);
    } on Object catch (error) {
      if (_current(op)) {
        _grant = null;
        _failed(error);
      }
    }
  }

  Future<void> _wait(Duration duration) async {
    if (_testWait != null) return _testWait(duration);
    final done = Completer<void>();
    _pause = done;
    _timer = Timer(duration, () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    if (identical(_pause, done)) {
      _pause = null;
      _timer = null;
    }
  }

  Future<void> _completeAuthorization(int op) async {
    final tokens = _candidate!;
    _show(GithubPhase.checking, '授权已返回，正在核对账号和仓库范围。');
    final verified = await _remote(_client.inspect(tokens.access));
    if (!_current(op)) return;
    final oldSelection = _saved?.accountId == verified.id
        ? _saved?.selectedRepositoryId
        : null;
    final selected =
        verified.repositories.any((r) => r.id == oldSelection && !r.archived)
        ? oldSelection
        : null;
    if (!await _save(
      GithubSavedSession(
        appId: config.appId,
        accountId: verified.id,
        tokens: tokens,
        selectedRepositoryId: selected,
      ),
      op,
    )) {
      return;
    }
    _candidate = null;
    account = verified;
    _show(GithubPhase.connected, _connectionMessage());
  }

  void cancelAuthorization() {
    if (_disposed || (!waiting && phase != GithubPhase.requesting)) return;
    _begin();
    _grant = null;
    _candidate = null;
    _show(
      _saved == null ? GithubPhase.unbound : GithubPhase.unavailable,
      '已停止本次等待，原本机记录保持原样。已在 GitHub 完成的授权需在官网单独撤销。',
    );
  }

  Future<void> retry() async {
    if (_disposed || busy || waiting) return;
    if (_disconnectPending) return disconnect();
    if (_candidate == null) return restore();
    final op = _begin();
    try {
      await _completeAuthorization(op);
    } on Object catch (error) {
      if (_current(op)) _failed(error);
    }
  }

  Future<void> selectRepository(int id) async {
    if (_disposed ||
        phase != GithubPhase.connected ||
        _saved == null ||
        !account!.repositories.any((r) => r.id == id && !r.archived)) {
      return;
    }
    final op = _begin();
    _show(GithubPhase.checking, '正在保存本机仓库选择。');
    try {
      if (await _save(_copy(_saved!, selected: id), op)) {
        _show(GithubPhase.connected, _connectionMessage());
      }
    } on Object catch (error) {
      if (_current(op)) _failed(error);
    }
  }

  Future<void> disconnect() async {
    if (_disposed) return;
    final op = _begin();
    _disconnectPending = true;
    _grant = null;
    _candidate = null;
    account = null;
    _show(GithubPhase.checking, '正在清除本机 GitHub 连接。');
    try {
      await _local(_storage.run(_store.delete));
      if (!_current(op)) return;
      _saved = null;
      _disconnectPending = false;
      _show(GithubPhase.unbound, '本机 GitHub 连接已清除；官网授权及云端运行需分别管理。');
    } on Object catch (error) {
      if (_current(op)) _failed(error);
    }
  }

  /// Used only by the explicit deployment action, never exposed in the UI.
  Future<GithubSavedSession> forDeployment() async {
    await restore();
    if (phase != GithubPhase.connected ||
        _saved == null ||
        !account!.repositories.any(
          (r) => r.id == _saved!.selectedRepositoryId && !r.archived,
        )) {
      throw const GithubFailure(GithubIssue.unauthorized);
    }
    return _saved!;
  }

  @override
  void dispose() {
    _disposed = true;
    _begin();
    _candidate = null;
    _grant = null;
    _saved = null;
    account = null;
    super.dispose();
  }
}
