import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/client_support.dart';
import 'package:rainclient/cloudflare/cloudflare_auth.dart';
import 'package:rainclient/cloudflare/cloudflare_controller.dart';
import 'package:rainclient/cloudflare/cloudflare_return_guard.dart';

import 'deployment_fakes.dart';

class FakeReturnGuard implements AuthReturnGuard {
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

class StubCloudWire extends Wire {
  final calls = <WireCall>[];
  late Future<WireReply> Function(WireCall) reply;
  @override
  Future<WireReply> send(
    String method,
    Uri uri, {
    String? token,
    String? body,
    String contentType = 'application/json',
  }) {
    final call = WireCall(method, uri, token, body, contentType);
    calls.add(call);
    return reply(call);
  }
}

class FakeCloudCallback extends CloudCallback {
  final result = Completer<String>();
  CloudPkce? pkce;
  int closes = 0;
  @override
  Future<void> start(CloudPkce value) async {
    pkce = value;
  }

  @override
  Future<String> get code => result.future;
  @override
  Future<void> close() async {
    closes++;
    if (!result.isCompleted) {
      result.completeError(const ClientFailure(ClientIssue.cancelled));
    }
  }
}

class FakeCloudGateway extends CloudGateway {
  static const session = CloudSession(
    token: 'synthetic_cloud_token',
    userId: 'synthetic-user',
    accountName: 'Synthetic account',
  );
  Completer<CloudSession>? exchangeGate;
  final exchangeStarted = Completer<void>();
  bool failInspect = false;
  @override
  Future<CloudSession> exchange(String code, CloudPkce pkce) async {
    if (!exchangeStarted.isCompleted) exchangeStarted.complete();
    return exchangeGate == null ? session : exchangeGate!.future;
  }

  @override
  Future<CloudSession> inspect(CloudSession session) async {
    if (failInspect) throw const ClientFailure(ClientIssue.network);
    return FakeCloudGateway.session;
  }
}

void main() {
  test(
    'callback lifetime starts and stops the background return guard',
    () async {
      final guard = FakeReturnGuard();
      final callback = LoopbackCloudCallback(port: 0, guard: guard);
      await callback.start(CloudPkce());
      expect(guard.starts, 1);
      await callback.close();
      expect(guard.stops, greaterThanOrEqualTo(1));
    },
  );
  test('failed socket binding also stops its background guard', () async {
    final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final guard = FakeReturnGuard();
    final callback = LoopbackCloudCallback(port: blocker.port, guard: guard);
    try {
      await expectLater(
        callback.start(CloudPkce()),
        throwsA(isA<SocketException>()),
      );
      expect(guard.stops, 1);
    } finally {
      await callback.close();
      await blocker.close();
    }
  });
  test('PKCE S256 matches the RFC7636 vector and adds no offline scope', () {
    final pkce = CloudPkce(
      verifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
      state: 'synthetic_state',
    );
    expect(pkce.challenge, 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    expect(
      pkce.authorization.queryParameters['scope']!.contains('offline_access'),
      isFalse,
    );
    expect(
      pkce.authorization.queryParameters.containsKey('client_secret'),
      isFalse,
    );
    expect(
      pkce.authorization.queryParameters['redirect_uri'],
      CloudConfig.redirect.toString(),
    );
  });
  test(
    'bad state and duplicated parameters do not produce a callback code',
    () {
      final pkce = CloudPkce(state: 'expected');
      expect(
        pkce.callbackCode(Uri.parse('/cloudflare/callback?state=wrong&code=x')),
        isNull,
      );
      expect(
        pkce.callbackCode(
          Uri.parse(
            '/cloudflare/callback?state=expected&state=expected&code=x',
          ),
        ),
        isNull,
      );
      expect(
        pkce.callbackCode(
          Uri.parse('/cloudflare/callback?state=expected&code=x&code=y'),
        ),
        isNull,
      );
      expect(
        pkce.callbackCode(
          Uri.parse('/cloudflare/callback?state=expected&code=synthetic_code'),
        ),
        'synthetic_code',
      );
    },
  );
  test('loopback rejects an invalid callback then receives a valid one exactly once', () async {
    final callback = LoopbackCloudCallback(port: 0);
    final pkce = CloudPkce(state: 'synthetic_expected');
    await callback.start(pkce);
    final http = HttpClient();
    Future<int> get(String query) async {
      final req = await http.getUrl(
        Uri.parse(
          'http://127.0.0.1:${callback.boundPort}/cloudflare/callback?$query',
        ),
      );
      final reply = await req.close();
      final status = reply.statusCode;
      final text = await reply.transform(utf8.decoder).join();
      expect(text.contains('synthetic_code'), isFalse);
      return status;
    }

    try {
      expect(await get('state=wrong&code=synthetic_code'), 403);
      expect(await get('state=synthetic_expected&code=synthetic_code'), 200);
      expect(await callback.code, 'synthetic_code');
      expect(await get('state=synthetic_expected&code=other_code'), 200);
      expect(await callback.code, 'synthetic_code');
    } finally {
      http.close(force: true);
      await callback.close();
    }
  });
  test('a closed callback cannot later bind a lingering server', () async {
    final callback = LoopbackCloudCallback(port: 0);
    await callback.close();
    await expectLater(
      callback.start(CloudPkce()),
      throwsA(isA<ClientFailure>()),
    );
  });
  test(
    'token exchange uses exact scope and only public client with verifier',
    () async {
      final wire = StubCloudWire();
      wire.reply = (_) async => WireReply(
        200,
        jsonEncode({
          'access_token': 'synthetic_token',
          'scope': CloudConfig.scopes.join(' '),
          'expires_in': 3600,
        }),
      );
      final client = CloudClient(
        wire: wire,
        now: () => DateTime.utc(2026, 10, 30),
      );
      final session = await client.exchange(
        'synthetic_code',
        CloudPkce(verifier: 'synthetic_verifier'),
      );
      expect(session.expiresAt, DateTime.utc(2026, 10, 30, 1));
      final form = Uri.splitQueryString(wire.calls.single.body!);
      expect(form['code_verifier'], 'synthetic_verifier');
      expect(form.containsKey('client_secret'), isFalse);
      wire.reply = (_) async => WireReply(
        200,
        jsonEncode({
          'access_token': 'synthetic_token',
          'scope': 'user-details.read',
        }),
      );
      await expectLater(
        client.exchange('synthetic_code', CloudPkce()),
        throwsA(isA<ClientFailure>()),
      );
    },
  );
  test('only the expected accepted membership is used and private profile fields are dropped', () async {
    final wire = StubCloudWire();
    wire.reply = (call) async => WireReply(
      200,
      jsonEncode({
        'success': true,
        'result': call.uri.path.endsWith('/user')
            ? {'id': 'synthetic-user', 'email': 'discarded@example.invalid'}
            : [
                {
                  'status': 'accepted',
                  'account': {
                    'id': CloudConfig.accountId,
                    'name': 'Synthetic account',
                  },
                },
              ],
      }),
    );
    final client = CloudClient(wire: wire);
    final checked = await client.inspect(FakeCloudGateway.session);
    expect(checked.accountName, 'Synthetic account');
    expect(checked.toJson().containsKey('email'), isFalse);
    expect(wire.calls.length, 2);
  });
  test(
    'read-only auth transport does not permit deployment or expanded domains',
    () {
      expect(
        CloudClient.allows(
          'GET',
          Uri.parse('https://api.cloudflare.com/client/v4/user'),
          true,
        ),
        isTrue,
      );
      expect(
        CloudClient.allows(
          'PUT',
          Uri.parse(
            'https://api.cloudflare.com/client/v4/accounts/x/workers/scripts/x',
          ),
          true,
        ),
        isFalse,
      );
      expect(
        CloudClient.allows(
          'POST',
          Uri.parse('https://example.com/oauth2/token'),
          false,
        ),
        isFalse,
      );
    },
  );
  test(
    'successful authorization persists an independently inspected session',
    () async {
      final store = MemoryRecordStore(),
          api = FakeCloudGateway(),
          callback = FakeCloudCallback();
      final c = CloudController(
        client: api,
        store: store,
        callbackFactory: () => callback,
      );
      try {
        await c.restore();
        final task = c.authorize((_) async {
          callback.result.complete('synthetic_code');
          return true;
        });
        await task;
        expect(c.phase, CloudPhase.connected);
        expect(store.value!['userId'], 'synthetic-user');
        await c.restore();
        expect(c.phase, CloudPhase.connected);
      } finally {
        c.dispose();
      }
    },
  );
  test('network failure keeps saved Cloudflare connection', () async {
    final store = MemoryRecordStore()
      ..value = FakeCloudGateway.session.toJson();
    final api = FakeCloudGateway()..failInspect = true;
    final c = CloudController(client: api, store: store);
    try {
      await c.restore();
      expect(c.phase, CloudPhase.unavailable);
      expect(store.value, isNotNull);
    } finally {
      c.dispose();
    }
  });
  test('late exchange after local disconnect cannot resurrect credentials on retry', () async {
    final store = MemoryRecordStore(),
        api = FakeCloudGateway(),
        callback = FakeCloudCallback();
    api.exchangeGate = Completer<CloudSession>();
    final c = CloudController(
      client: api,
      store: store,
      callbackFactory: () => callback,
    );
    try {
      await c.restore();
      final task = c.authorize((_) async {
        callback.result.complete('synthetic_code');
        return true;
      });
      await api.exchangeStarted.future;
      await c.disconnect();
      api.exchangeGate!.complete(FakeCloudGateway.session);
      await task;
      await c.retry();
      expect(c.phase, CloudPhase.unbound);
      expect(store.value, isNull);
    } finally {
      c.dispose();
    }
  });
  test('cancel waiting leaves previous session intact', () async {
    final store = MemoryRecordStore()
      ..value = FakeCloudGateway.session.toJson();
    final callback = FakeCloudCallback(),
        c = CloudController(
          client: FakeCloudGateway(),
          store: store,
          callbackFactory: () => callback,
        );
    try {
      await c.restore();
      final opened = Completer<void>();
      final task = c.authorize((_) async {
        opened.complete();
        return true;
      });
      await opened.future;
      c.cancelAuthorization();
      await task;
      expect(store.value, isNotNull);
      expect(c.phase, CloudPhase.unavailable);
    } finally {
      c.dispose();
    }
  });
  test('local save failure retries verified candidate without another code exchange', () async {
    final store = MemoryRecordStore()..failWrite = true;
    final callback = FakeCloudCallback(),
        c = CloudController(
          client: FakeCloudGateway(),
          store: store,
          callbackFactory: () => callback,
        );
    try {
      await c.restore();
      await c.authorize((_) async {
        callback.result.complete('synthetic_code');
        return true;
      });
      expect(c.phase, CloudPhase.error);
      store.failWrite = false;
      await c.retry();
      expect(c.phase, CloudPhase.connected);
    } finally {
      c.dispose();
    }
  });
}
