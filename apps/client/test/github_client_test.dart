import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/github/github_client.dart';
import 'package:rainclient/github/github_models.dart';

import 'github_fakes.dart';

class RecordedGithubCall {
  RecordedGithubCall(this.uri, this.token, this.form);
  final Uri uri;
  final String? token;
  final Map<String, String>? form;
}

class StubGithubTransport extends GithubTransport {
  final calls = <RecordedGithubCall>[];
  late Future<GithubReply> Function(RecordedGithubCall) reply;

  @override
  Future<GithubReply> send(
    Uri uri, {
    String? token,
    Map<String, String>? form,
  }) {
    final call = RecordedGithubCall(uri, token, form);
    calls.add(call);
    return reply(call);
  }
}

Matcher githubIssue(GithubIssue issue) =>
    isA<GithubFailure>().having((e) => e.issue, 'safe issue', issue);

Map<String, dynamic> syntheticExchange() => {
  'access_token': 'synthetic_access_token',
  'refresh_token': 'synthetic_refresh_token',
  'expires_in': 28800,
  'refresh_token_expires_in': 15724800,
  'token_type': 'bearer',
};

Map<String, dynamic> syntheticInstallation({int id = 123, int app = 5504900}) =>
    {
      'id': id,
      'app_id': app,
      'account': {'login': 'frewily'},
      'repository_selection': 'selected',
      'suspended_at': null,
      'permissions': {...GithubAppConfig.permissions},
    };

GithubReply ok(Object body) => GithubReply(200, jsonEncode(body));

void main() {
  late StubGithubTransport transport;
  late GithubClient client;
  setUp(() {
    transport = StubGithubTransport();
    client = GithubClient(transport: transport, now: () => githubTestNow);
  });

  test(
    'transport restricts credentials to official read and OAuth endpoints',
    () {
      bool read(String path) => DartGithubTransport.allows(Uri.parse(path));
      expect(read('https://api.github.com/user'), isTrue);
      expect(
        read(
          'https://api.github.com/user/installations/123/repositories?per_page=100&page=1',
        ),
        isTrue,
      );
      for (final path in [
        'http://api.github.com/user',
        'https://example.com/user',
        'https://api.github.com.evil.example/user',
        'https://x@api.github.com/user',
        'https://api.github.com:444/user',
        'https://api.github.com/user#fragment',
        'https://api.github.com/repos/frewily/example/actions/workflows/run/dispatches',
        'https://api.github.com/user/installations?per_page=100&page=11',
        'https://api.github.com/user/installations?per_page=100&page=1&page=2',
        'https://github.com/login/oauth/access_token',
      ]) {
        expect(read(path), isFalse, reason: path);
      }
      expect(
        DartGithubTransport.allows(
          Uri.parse('https://github.com/login/oauth/access_token'),
          oauth: true,
        ),
        isTrue,
      );
      expect(
        DartGithubTransport.allows(
          Uri.parse('https://github.com/login/oauth/access_token?code=x'),
          oauth: true,
        ),
        isFalse,
      );
    },
  );

  test(
    'device flow uses public client id, bounded lifetime and official URL',
    () async {
      transport.reply = (_) async => ok({
        'device_code': 'synthetic_device',
        'user_code': 'ABCD-1234',
        'verification_uri': 'https://github.com/login/device',
        'expires_in': 900,
        'interval': 1,
      });
      final grant = await client.startAuthorization();
      expect(grant.interval, const Duration(seconds: 5));
      expect(
        grant.expiresAt.difference(githubTestNow),
        const Duration(minutes: 15),
      );
      expect(transport.calls.single.form, {
        'client_id': 'Iv23li36LZrIGh5lZQOR',
        'scope': 'offline_access',
      });
      expect(transport.calls.single.token, isNull);
    },
  );

  test('untrusted verification links are rejected', () async {
    transport.reply = (_) async => ok({
      'device_code': 'synthetic_device',
      'user_code': 'ABCD-1234',
      'verification_uri': 'https://example.com/login',
      'expires_in': 900,
    });
    await expectLater(
      client.startAuthorization(),
      throwsA(githubIssue(GithubIssue.response)),
    );
  });

  test(
    'polling distinguishes pending, slow down and authorized without secrets',
    () async {
      final grant = FakeGithubGateway().grant;
      for (final error in ['authorization_pending', 'slow_down']) {
        transport.reply = (_) async => ok({'error': error});
        final poll = await client.poll(grant);
        expect(
          poll.state,
          error == 'slow_down'
              ? GithubPollState.slowDown
              : GithubPollState.pending,
        );
      }
      transport.reply = (_) async => ok(syntheticExchange());
      expect(
        (await client.poll(grant)).tokens!.access,
        'synthetic_access_token',
      );
      for (final call in transport.calls) {
        expect(call.form!.containsKey('client_secret'), isFalse);
        expect(call.token, isNull);
      }
    },
  );

  test('expired device grant sends no request', () async {
    final grant = GithubDeviceGrant(
      deviceCode: 'synthetic_device',
      userCode: 'ABCD-1234',
      expiresAt: githubTestNow,
      interval: const Duration(seconds: 5),
    );
    await expectLater(
      client.poll(grant),
      throwsA(githubIssue(GithubIssue.expired)),
    );
    expect(transport.calls, isEmpty);
  });

  test('denial and server expiry have safe separate outcomes', () async {
    for (final entry in {
      'access_denied': GithubIssue.denied,
      'expired_token': GithubIssue.expired,
    }.entries) {
      transport.reply = (_) async => ok({'error': entry.key});
      await expectLater(
        client.poll(FakeGithubGateway().grant),
        throwsA(githubIssue(entry.value)),
      );
    }
  });

  test('refresh sends rotating credential only to token endpoint without client secret', () async {
    transport.reply = (_) async => ok(syntheticExchange());
    await client.refresh('synthetic_refresh_old');
    expect(
      transport.calls.single.uri.toString(),
      'https://github.com/login/oauth/access_token',
    );
    expect(transport.calls.single.form, {
      'client_id': 'Iv23li36LZrIGh5lZQOR',
      'grant_type': 'refresh_token',
      'refresh_token': 'synthetic_refresh_old',
    });
  });

  test('malformed and partial expiring token pairs are rejected', () {
    for (final bad in [
      {...syntheticExchange(), 'refresh_token': null},
      {...syntheticExchange(), 'expires_in': 0},
      {...syntheticExchange(), 'access_token': 'unsafe\r\nheader'},
      {...syntheticExchange(), 'token_type': 'other'},
    ]) {
      expect(
        () => GithubTokens.fromExchange(bad, githubTestNow),
        throwsA(githubIssue(GithubIssue.response)),
      );
    }
  });

  test(
    'only configured application installation repositories are listed',
    () async {
      transport.reply = (call) async {
        if (call.uri.path == '/user') {
          return ok({
            'id': 1,
            'login': 'frewily',
            'email': 'discarded@example.invalid',
          });
        }
        if (call.uri.path == '/user/installations') {
          return ok({
            'total_count': 2,
            'installations': [
              syntheticInstallation(),
              syntheticInstallation(id: 999, app: 111),
            ],
          });
        }
        expect(call.uri.path, '/user/installations/123/repositories');
        return ok({
          'total_count': 1,
          'repositories': [
            {
              'id': 101,
              'full_name': 'frewily/rain-client-s0-target-20261027',
              'private': false,
              'archived': false,
            },
          ],
        });
      };
      final account = await client.inspect('synthetic_access_token');
      expect(account.login, 'frewily');
      expect(account.repositories.single.id, 101);
      expect(transport.calls.length, 3);
      expect(transport.calls.every((call) => call.form == null), isTrue);
    },
  );

  test(
    'unexpected account and expanded installation permission fail closed',
    () async {
      transport.reply = (_) async => ok({'id': 1, 'login': 'another-account'});
      await expectLater(
        client.inspect('synthetic_access_token'),
        throwsA(githubIssue(GithubIssue.scope)),
      );
      transport.reply = (call) async {
        if (call.uri.path == '/user') return ok({'id': 1, 'login': 'frewily'});
        final installation = syntheticInstallation();
        installation['repository_selection'] = 'all';
        return ok({
          'total_count': 1,
          'installations': [installation],
        });
      };
      await expectLater(
        client.inspect('synthetic_access_token'),
        throwsA(githubIssue(GithubIssue.scope)),
      );
      expect(
        transport.calls.any((c) => c.uri.path.endsWith('/repositories')),
        isFalse,
      );
    },
  );

  test(
    'repository pagination includes later pages with bounded counts',
    () async {
      transport.reply = (call) async {
        if (call.uri.path == '/user') return ok({'id': 1, 'login': 'frewily'});
        if (call.uri.path == '/user/installations') {
          return ok({
            'total_count': 1,
            'installations': [syntheticInstallation()],
          });
        }
        final page = int.parse(call.uri.queryParameters['page']!);
        return ok({
          'total_count': 101,
          'repositories': [
            for (
              var id = page == 1 ? 1 : 101;
              id <= (page == 1 ? 100 : 101);
              id++
            )
              {
                'id': id,
                'full_name': 'frewily/repo$id',
                'private': true,
                'archived': false,
              },
          ],
        });
      };
      expect(
        (await client.inspect('synthetic_access_token')).repositories.length,
        101,
      );
      expect(transport.calls.last.uri.queryParameters['page'], '2');
    },
  );

  test(
    'cancellation after late profile response prevents subsequent requests',
    () async {
      final gate = Completer<GithubReply>();
      transport.reply = (_) => gate.future;
      final task = client.inspect('synthetic_access_token');
      client.cancelPending();
      gate.complete(ok({'id': 1, 'login': 'frewily'}));
      await expectLater(task, throwsA(githubIssue(GithubIssue.network)));
      expect(transport.calls.length, 1);
    },
  );

  test(
    'unknown forbidden replies do not masquerade as revoked authorization',
    () async {
      transport.reply = (_) async =>
          const GithubReply(403, 'private remote error text');
      await expectLater(
        client.inspect('synthetic_access_token'),
        throwsA(githubIssue(GithubIssue.forbidden)),
      );
      transport.reply = (_) async =>
          const GithubReply(200, '<html>sign in</html>');
      await expectLater(
        client.inspect('synthetic_access_token'),
        throwsA(githubIssue(GithubIssue.response)),
      );
    },
  );

  test(
    'saved credential format round trips including rotation and repository',
    () {
      final saved = syntheticGithubSaved(pending: true, selected: 101);
      final restored = GithubSavedSession.fromJson(
        jsonDecode(jsonEncode(saved.toJson())),
      );
      expect(restored.tokens.access, saved.tokens.access);
      expect(restored.refreshPending, isTrue);
      expect(restored.selectedRepositoryId, 101);
    },
  );
}
