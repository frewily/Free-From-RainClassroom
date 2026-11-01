import 'dart:async';

import 'package:flutter/services.dart';

import '../client_support.dart';
import 'cloudflare_auth.dart';
import 'cloudflare_return_guard.dart';

class NativeCloudCallback extends CloudCallback {
  NativeCloudCallback({MethodChannel? channel, AuthReturnGuard? guard})
    : channel =
          channel ??
          const MethodChannel('top.frewily.rainclient/cloudflare_callback'),
      guard = guard ?? PlatformAuthReturnGuard();
  final MethodChannel channel;
  final AuthReturnGuard guard;
  final owner = secureNonce(24);
  final _code = Completer<String>();
  bool _closed = false;

  @override
  Future<String> get code => _code.future;
  @override
  Future<void> start(CloudPkce pkce) async {
    unawaited(
      _code.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    await guard.start();
    if (_closed) {
      await guard.stop();
      throw const ClientFailure(ClientIssue.cancelled);
    }
    final ready = await channel.invokeMethod<bool>('start', {
      'owner': owner,
      'state': pkce.state,
    });
    if (ready != true || _closed) {
      await close();
      throw const ClientFailure(ClientIssue.conflict);
    }
    unawaited(_receive(pkce));
  }

  Future<void> _receive(CloudPkce pkce) async {
    try {
      final result = await channel.invokeMethod<String>('await', {
        'owner': owner,
      });
      if (_closed) return;
      final uri = result == null ? null : Uri.tryParse(result);
      if (uri == null ||
          uri.scheme != 'http' ||
          uri.host != '127.0.0.1' ||
          uri.port != 8765 ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment) {
        throw const ClientFailure(ClientIssue.authorization);
      }
      final code = pkce.callbackCode(uri);
      if (code == null) throw const ClientFailure(ClientIssue.authorization);
      if (!_code.isCompleted) _code.complete(code);
    } on Object {
      if (!_closed && !_code.isCompleted) {
        _code.completeError(const ClientFailure(ClientIssue.authorization));
      }
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    if (!_code.isCompleted) {
      unawaited(
        _code.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      _code.completeError(const ClientFailure(ClientIssue.cancelled));
    }
    try {
      await channel.invokeMethod<bool>('stop', {'owner': owner});
    } finally {
      await guard.stop();
    }
  }
}
