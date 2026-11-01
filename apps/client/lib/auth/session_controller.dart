import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cookie_reader.dart';
import 'session_client.dart';
import 'session_cookie.dart';
import 'session_store.dart';

enum LoginPhase {
  preparing,
  loggedOut,
  loggingIn,
  checking,
  loggedIn,
  needsLogin,
  unavailable,
  error,
}

enum _Recovery { restore, beginLogin, save, cancel, logout }

/// Serializing storage matters: a pending save must finish before logout deletes
/// it. A timeout reports failure to the UI without releasing the underlying queue.
class _SerialActions {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

class SessionController extends ChangeNotifier {
  SessionController({
    required this._store,
    required this._verifier,
    required this._cookies,
    Future<void> Function()? closeLoginView,
    this.ioTimeout = const Duration(seconds: 8),
  }) : _closeLoginView = closeLoginView ?? (() async {});

  final SessionStore _store;
  final SessionVerifier _verifier;
  final SessionCookieSource _cookies;
  final Future<void> Function() _closeLoginView;
  final Duration ioTimeout;
  final _storage = _SerialActions();
  final _cookieActions = _SerialActions();

  LoginPhase phase = LoginPhase.preparing;
  String message = '正在检查本机保存功能。';
  SessionCheck? lastCheck;
  bool hasSavedSession = false;
  bool inLoginFlow = false;
  bool _disposed = false;
  bool _logoutPending = false;
  int _generation = 0;
  String? _pendingCandidate;
  String? _beforeLogin;
  _Recovery _recovery = _Recovery.restore;

  bool get busy =>
      phase == LoginPhase.preparing || phase == LoginPhase.checking;

  int _beginOperation() {
    _generation++;
    _verifier.cancelPending();
    return _generation;
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  void _show(LoginPhase value, String text, [_Recovery? recovery]) {
    if (_disposed) return;
    phase = value;
    message = text;
    if (recovery != null) _recovery = recovery;
    notifyListeners();
  }

  Future<T> _io<T>(Future<T> future) => future.timeout(ioTimeout);

  Future<void> _closeAndClear() => _io(
    _cookieActions.run(() async {
      await _closeLoginView();
      await _cookies.clear();
    }),
  );

  Future<void> restore() async {
    if (_disposed) return;
    if (_logoutPending) return logout();
    final operation = _beginOperation();
    _pendingCandidate = null;
    _beforeLogin = null;
    inLoginFlow = false;
    _show(LoginPhase.preparing, '正在读取本机登录信息。', _Recovery.restore);
    try {
      await _closeAndClear();
      if (!_current(operation)) return;
      await _loadSaved(operation);
    } on Object {
      if (_current(operation)) {
        _show(
          LoginPhase.error,
          '暂时无法读取或清理本机登录信息，请重试。',
          _logoutPending ? _Recovery.logout : _Recovery.restore,
        );
      }
    }
  }

  Future<void> _loadSaved(int operation) async {
    final saved = await _io(_storage.run(_store.read));
    if (!_current(operation)) return;
    hasSavedSession = saved != null;
    if (saved == null) {
      await _io(_storage.run(_store.checkReady));
      if (!_current(operation)) return;
      _show(LoginPhase.loggedOut, '在官方页面完成登录后，即可安全保存在这台设备。', _Recovery.restore);
      return;
    }
    _show(LoginPhase.checking, '正在确认已保存的登录是否有效。');
    final result = await _verifier.verify(saved);
    if (!_current(operation)) return;
    lastCheck = result;
    switch (result.verdict) {
      case SessionVerdict.valid:
        _show(LoginPhase.loggedIn, '本机登录已通过检查，重新打开应用时可以恢复。', _Recovery.restore);
      case SessionVerdict.invalid:
        _logoutPending = true;
        await _io(
          _storage.run(() async {
            if (_current(operation)) await _store.delete();
          }),
        );
        if (!_current(operation)) return;
        _logoutPending = false;
        hasSavedSession = false;
        _show(LoginPhase.needsLogin, '雨课堂已确认登录信息失效，请重新登录。', _Recovery.restore);
      case SessionVerdict.unavailable:
        _show(
          LoginPhase.unavailable,
          '暂时无法确认登录状态，已保留本机登录信息。可稍后重试。',
          _Recovery.restore,
        );
    }
  }

  Future<bool> beginLogin() async {
    if (_logoutPending || _disposed) return false;
    final operation = _beginOperation();
    _pendingCandidate = null;
    _show(LoginPhase.preparing, '正在准备官方登录页面。');
    try {
      final previous = await _io(_storage.run(_store.read));
      if (!_current(operation)) return false;
      _beforeLogin = previous;
      await _closeAndClear();
      if (!_current(operation)) return false;
      inLoginFlow = true;
      lastCheck = null;
      _show(LoginPhase.loggingIn, '完成官方页面的登录操作后，点击下方检查按钮。');
      return true;
    } on Object {
      if (_current(operation)) {
        _show(LoginPhase.error, '暂时无法准备登录页面，请重试。', _Recovery.beginLogin);
      }
      return false;
    }
  }

  Future<bool> checkLogin() async {
    if (!inLoginFlow || busy || _disposed) return false;
    final operation = _beginOperation();
    _show(LoginPhase.checking, '正在检查雨课堂登录状态。');
    try {
      final candidate = await _io(_cookieActions.run(_cookies.read));
      if (!_current(operation)) return false;
      if (candidate == null || !isSafeSessionValue(candidate)) {
        _show(LoginPhase.loggingIn, '尚未取得可检查的登录信息，请先完成官方页面的操作。');
        return false;
      }
      final result = await _verifier.verify(candidate);
      if (!_current(operation)) return false;
      lastCheck = result;
      switch (result.verdict) {
        case SessionVerdict.valid:
          _pendingCandidate = candidate;
          return await _saveCandidate(operation, candidate);
        case SessionVerdict.invalid:
          _show(LoginPhase.loggingIn, '登录还没有通过检查，请继续完成官方页面的操作后重试。');
        case SessionVerdict.unavailable:
          _show(LoginPhase.loggingIn, '暂时无法检查登录状态。请确认网络后再试，已有登录信息会保留。');
      }
    } on Object {
      if (_current(operation)) {
        _show(LoginPhase.loggingIn, '暂时无法读取登录状态，请重试或取消后重新打开官方页面。');
      }
    }
    return false;
  }

  Future<bool> _saveCandidate(int operation, String candidate) async {
    try {
      _show(LoginPhase.checking, '登录已通过检查，正在安全保存。');
      await _closeAndClear();
      if (!_current(operation)) return false;
      await _io(
        _storage.run(() async {
          if (_current(operation)) await _store.write(candidate);
        }),
      );
      if (!_current(operation)) return false;
      _pendingCandidate = null;
      _beforeLogin = null;
      inLoginFlow = false;
      hasSavedSession = true;
      _show(LoginPhase.loggedIn, '登录已通过检查并安全保存在本机。', _Recovery.restore);
      return true;
    } on Object {
      if (_current(operation)) {
        inLoginFlow = false;
        _show(LoginPhase.error, '登录保存或登录窗口清理尚未完成，请重试。', _Recovery.save);
      }
      return false;
    }
  }

  Future<void> cancelLogin() async {
    if (_disposed ||
        _logoutPending ||
        (!inLoginFlow &&
            _pendingCandidate == null &&
            _recovery != _Recovery.cancel)) {
      return;
    }
    final operation = _beginOperation();
    final previous = _beforeLogin;
    _pendingCandidate = null;
    inLoginFlow = false;
    _show(LoginPhase.preparing, '正在取消本次登录。');
    try {
      await _closeAndClear();
      if (!_current(operation)) return;
      // This rollback is ordered after any save that was already in flight.
      await _io(
        _storage.run(() async {
          if (!_current(operation)) return;
          if (previous == null) {
            await _store.delete();
          } else {
            await _store.write(previous);
          }
        }),
      );
      if (!_current(operation)) return;
      _beforeLogin = null;
      await _loadSaved(operation);
    } on Object {
      if (_current(operation)) {
        _show(
          LoginPhase.error,
          '本次登录尚未完全取消，请重试清理。',
          _logoutPending ? _Recovery.logout : _Recovery.cancel,
        );
      }
    }
  }

  Future<void> logout() async {
    if (_disposed) return;
    final operation = _beginOperation();
    _logoutPending = true;
    _pendingCandidate = null;
    _beforeLogin = null;
    inLoginFlow = false;
    _show(LoginPhase.preparing, '正在清除本机登录信息。');
    var failed = false;
    try {
      await _closeAndClear();
    } on Object {
      failed = true;
    }
    // Still delete encrypted storage if cookie cleanup failed.
    try {
      await _io(_storage.run(_store.delete));
    } on Object {
      failed = true;
    }
    if (!_current(operation)) return;
    if (failed) {
      _show(LoginPhase.error, '退出本机登录尚未完成，请重试清除。', _Recovery.logout);
      return;
    }
    _logoutPending = false;
    hasSavedSession = false;
    lastCheck = null;
    _show(LoginPhase.loggedOut, '已退出本机登录。云端监听的启停是独立操作。', _Recovery.restore);
  }

  Future<void> retry() async {
    if (_disposed) return;
    switch (_recovery) {
      case _Recovery.beginLogin:
        await beginLogin();
      case _Recovery.cancel:
        await cancelLogin();
      case _Recovery.logout:
        await logout();
      case _Recovery.restore:
        await restore();
      case _Recovery.save:
        final candidate = _pendingCandidate;
        if (candidate == null) return restore();
        final operation = _beginOperation();
        _show(LoginPhase.checking, '正在重新确认待保存的登录信息。');
        final result = await _verifier.verify(candidate);
        if (!_current(operation)) return;
        lastCheck = result;
        if (result.verdict == SessionVerdict.valid) {
          await _saveCandidate(operation, candidate);
        } else {
          _show(LoginPhase.error, '暂时无法完成保存，请稍后重试或清除本机登录。', _Recovery.save);
        }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _pendingCandidate = null;
    _beforeLogin = null;
    _verifier.cancelPending();
    super.dispose();
  }
}
