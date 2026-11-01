import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/cloudflare/cloudflare_auth.dart';
import 'package:rainclient/cloudflare/native_cloudflare_callback.dart';
import 'package:rainclient/cloudflare/cloudflare_return_guard.dart';
import 'package:rainclient/client_support.dart';

class DummyGuard implements AuthReturnGuard {
  int starts = 0, stops = 0;
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('top.frewily.rainclient/cloudflare_callback');
  final calls = <MethodCall>[];
  late Completer<String> returned;
  setUp(() {
    calls.clear();
    returned = Completer<String>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'await') return returned.future;
          return true;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'native return is independently checked with the original PKCE state',
    () async {
      final guard = DummyGuard(),
          pkce = CloudPkce(state: 'synthetic_expected_state');
      final receiver = NativeCloudCallback(channel: channel, guard: guard);
      await receiver.start(pkce);
      returned.complete(
        'http://127.0.0.1:8765/cloudflare/callback?state=synthetic_expected_state&code=synthetic_code',
      );
      expect(await receiver.code, 'synthetic_code');
      await receiver.close();
      expect(guard.starts, 1);
      expect(guard.stops, 1);
      expect(calls.first.arguments['state'], pkce.state);
    },
  );
  test('native message from another origin or state is rejected', () async {
    final receiver = NativeCloudCallback(channel: channel, guard: DummyGuard());
    await receiver.start(CloudPkce(state: 'expected'));
    returned.complete(
      'https://example.com/cloudflare/callback?state=expected&code=synthetic_code',
    );
    await expectLater(receiver.code, throwsA(isA<ClientFailure>()));
    await receiver.close();
  });
  test('late native result cannot restore a cancelled return', () async {
    final receiver = NativeCloudCallback(channel: channel, guard: DummyGuard());
    final result = receiver.code;
    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    await receiver.start(CloudPkce(state: 'expected'));
    await receiver.close();
    returned.complete(
      'http://127.0.0.1:8765/cloudflare/callback?state=expected&code=synthetic_code',
    );
    await expectLater(result, throwsA(isA<ClientFailure>()));
  });
}
