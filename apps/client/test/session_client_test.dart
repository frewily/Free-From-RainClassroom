import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/auth/session_client.dart';

class StubTransport extends SessionTransport {
  StubTransport(this.response);
  final Future<SessionReply> Function() response;
  int calls = 0;
  @override
  Future<SessionReply> fetch(String session) {
    calls++;
    return response();
  }
}

void main() {
  test('200 requires a usable identity record, not just a successful page', () {
    for (final body in [
      '{"data":[{"name":"Synthetic"}]}',
      '{"data":[{"user_id":1}]}',
    ]) {
      expect(
        SessionClient.classify(SessionReply(200, body)).verdict,
        SessionVerdict.valid,
      );
    }
    for (final body in [
      '{}',
      '{"data":[]}',
      '{"data":[{}]}',
      '{"errcode":5,"data":[{"id":1}]}',
      '<html>login</html>',
    ]) {
      expect(
        SessionClient.classify(SessionReply(200, body)).verdict,
        SessionVerdict.unavailable,
      );
    }
  });

  test(
    'only observed explicit authentication responses classify as invalid',
    () {
      for (final code in [401000, 401002]) {
        expect(
          SessionClient.classify(SessionReply(401, '{"errcode":$code}'))
              .verdict,
          SessionVerdict.invalid,
        );
      }
      for (final reply in [
        const SessionReply(401, '<html>proxy</html>'),
        const SessionReply(403, '{"error":"forbidden"}'),
        const SessionReply(503, '{"data":[{"id":1}]}'),
        const SessionReply(302, ''),
      ]) {
        expect(
          SessionClient.classify(reply).verdict,
          SessionVerdict.unavailable,
        );
      }
    },
  );

  test(
    'network and timeout failures remain temporary verification failures',
    () async {
      final timeout = SessionClient(
        transport: StubTransport(
          () => Future.error(TimeoutException('synthetic')),
        ),
      );
      final network = SessionClient(
        transport: StubTransport(
          () => Future.error(const SocketException('synthetic')),
        ),
      );
      expect((await timeout.verify('synthetic')).issue, CheckIssue.timeout);
      expect((await network.verify('synthetic')).issue, CheckIssue.network);
    },
  );

  test('unsafe values never reach the network transport', () async {
    final transport = StubTransport(
      () async => const SessionReply(200, '{"data":[{"id":1}]}'),
    );
    await SessionClient(transport: transport).verify('synthetic\r\ninjection');
    expect(transport.calls, 0);
    expect(
      DartSessionTransport.endpoint.toString(),
      'https://changjiang.yuketang.cn/v2/api/web/userinfo',
    );
  });
}
