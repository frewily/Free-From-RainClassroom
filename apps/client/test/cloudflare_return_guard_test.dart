import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/client_support.dart';
import 'package:rainclient/cloudflare/cloudflare_return_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('top.frewily.rainclient/cloudflare_return');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'native guard receives only an opaque owner, never an OAuth code or URL',
    () async {
      final guard = PlatformAuthReturnGuard(enabled: true, channel: channel);
      await guard.start();
      await guard.stop();
      expect(calls.map((c) => c.method), ['start', 'stop']);
      for (final call in calls) {
        expect((call.arguments as Map).keys, ['owner']);
        expect(call.arguments['owner'], guard.owner);
      }
    },
  );
  test(
    'late native start is stopped when cancellation arrived first',
    () async {
      final gate = Completer<bool>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'start' ? gate.future : true;
          });
      final guard = PlatformAuthReturnGuard(enabled: true, channel: channel);
      final start = guard.start();
      final stopped = guard.stop();
      gate.complete(true);
      await expectLater(start, throwsA(isA<ClientFailure>()));
      await stopped;
      expect(calls.where((c) => c.method == 'stop'), isNotEmpty);
      expect(calls.every((c) => c.arguments['owner'] == guard.owner), isTrue);
    },
  );
  test(
    'a previously closed guard cannot begin another background window',
    () async {
      final guard = PlatformAuthReturnGuard(enabled: true, channel: channel);
      await guard.stop();
      await expectLater(guard.start(), throwsA(isA<ClientFailure>()));
      expect(calls, isEmpty);
    },
  );
  test('separate attempts use distinct ownership identifiers', () {
    expect(
      PlatformAuthReturnGuard(enabled: true).owner,
      isNot(PlatformAuthReturnGuard(enabled: true).owner),
    );
  });
}
