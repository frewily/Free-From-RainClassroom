import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/auth/login_navigation.dart';
import 'package:rainclient/auth/session_cookie.dart';

void main() {
  test('only sessionid is selected, preserving equals signs and encoding', () {
    expect(
      parseSessionCookieHeader('csrf=other; sessionid=a=b==; extra=1'),
      'a=b==',
    );
    expect(parseSessionCookieHeader('sessionid=a%2Fb'), 'a%2Fb');
    expect(
      parseSessionCookieHeader('sessionid=first; sessionid=first'),
      'first',
    );
  });

  test('missing, empty and unrelated cookie names are not sessions', () {
    for (final value in [
      null,
      '',
      'csrf=value',
      'sessionid=',
      'sessionid_other=x',
    ]) {
      expect(parseSessionCookieHeader(value), isNull);
    }
  });

  test(
    'ambiguous or unsafe cookie contents fail without exposing their value',
    () {
      for (final header in [
        'sessionid=one; sessionid=two',
        'sessionid=synthetic\r\ninjected=value',
        'sessionid=has space',
        'sessionid=${'x' * 4097}',
      ]) {
        expect(
          () => parseSessionCookieHeader(header),
          throwsA(isA<SessionCookieException>()),
        );
      }
    },
  );

  test('login navigation accepts fixed official HTTPS hosts only', () {
    expect(
      allowsLoginNavigation(Uri.parse('https://changjiang.yuketang.cn/web')),
      isTrue,
    );
    expect(
      allowsLoginNavigation(
        Uri.parse('https://open.weixin.qq.com/connect/qrconnect'),
      ),
      isTrue,
    );
    for (final url in [
      'http://changjiang.yuketang.cn/web',
      'https://changjiang.yuketang.cn.evil.invalid/',
      'https://user@changjiang.yuketang.cn/',
      'https://changjiang.yuketang.cn:8443/',
      'file:///etc/passwd',
      'javascript:alert(1)',
      'intent://example',
    ]) {
      expect(allowsLoginNavigation(Uri.parse(url)), isFalse);
    }
  });

  test('opening WeChat requires a trusted current page and a weixin URL', () {
    final wechat = Uri.parse('weixin://dl/scan');
    expect(allowsWechatLaunch(wechat, 'open.weixin.qq.com'), isTrue);
    expect(allowsWechatLaunch(wechat, null), isFalse);
    expect(allowsWechatLaunch(wechat, 'untrusted.invalid'), isFalse);
    expect(
      allowsWechatLaunch(Uri.parse('intent://example'), 'open.weixin.qq.com'),
      isFalse,
    );
  });
}
