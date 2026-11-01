import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import '../client_support.dart';

abstract interface class AuthReturnGuard {
  Future<void> start();
  Future<void> stop();
}

/// Keep the native callback receiver runnable while the system browser is open.
/// Only an unrelated opaque owner ID crosses this channel, never OAuth data.
class PlatformAuthReturnGuard implements AuthReturnGuard {
  PlatformAuthReturnGuard({bool? enabled, MethodChannel? channel})
    : enabled = enabled ?? Platform.isAndroid,
      channel =
          channel ??
          const MethodChannel('top.frewily.rainclient/cloudflare_return'),
      owner = base64Url
          .encode(List.generate(24, (_) => Random.secure().nextInt(256)))
          .replaceAll('=', '');

  final bool enabled;
  final MethodChannel channel;
  final String owner;
  Future<void>? _starting;
  bool _closed = false;

  @override
  Future<void> start() async {
    if (_closed) throw const ClientFailure(ClientIssue.cancelled);
    if (!enabled) return;
    final starting = _starting ??= _startNative();
    await starting;
    if (_closed) {
      await channel.invokeMethod<bool>('stop', {'owner': owner});
      throw const ClientFailure(ClientIssue.cancelled);
    }
  }

  Future<void> _startNative() async {
    try {
      if (await channel.invokeMethod<bool>('start', {'owner': owner}) != true) {
        throw const ClientFailure(ClientIssue.conflict);
      }
    } on Object {
      throw const ClientFailure(ClientIssue.conflict);
    }
  }

  @override
  Future<void> stop() async {
    _closed = true;
    if (!enabled || _starting == null) return;
    try {
      await _starting;
    } on Object {
      return;
    }
    await channel.invokeMethod<bool>('stop', {'owner': owner});
  }
}
