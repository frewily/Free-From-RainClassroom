import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'session_cookie.dart';

abstract interface class SessionCookieSource {
  Future<String?> read();
  Future<void> clear();
}

class PlatformSessionCookies implements SessionCookieSource {
  PlatformSessionCookies({WebViewCookieManager? manager})
    : _manager = manager ?? WebViewCookieManager();

  final WebViewCookieManager _manager;
  static const _channel = MethodChannel(
    'top.frewily.rainclient/session_cookie',
  );
  static final origin = Uri.parse('https://changjiang.yuketang.cn/');

  @override
  Future<String?> read() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      // The bridge has no URL argument and is not exposed to web-page JS.
      final header = await _channel.invokeMethod<String>('readCookieHeader');
      return parseSessionCookieHeader(header);
    }
    final cookies = await _manager.getCookies(domain: origin);
    final sessions = cookies.where((cookie) => cookie.name == 'sessionid');
    return parseSessionCookieHeader(
      sessions.map((cookie) => 'sessionid=${cookie.value}').join('; '),
    );
  }

  @override
  Future<void> clear() async {
    // This app's only embedded login container is currently Rain Classroom.
    await _manager.clearCookies();
    if (await read() != null) throw const SessionCookieException();
  }
}
