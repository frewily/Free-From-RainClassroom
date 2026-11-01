import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'github_models.dart';

class GithubReply {
  const GithubReply(this.status, this.body);
  final int status;
  final String body;
}

abstract class GithubTransport {
  Future<GithubReply> send(Uri uri, {String? token, Map<String, String>? form});
  void cancelPending() {}
}

/// This slice can only GET account/installation metadata and POST OAuth forms.
/// It cannot write repository files, settings, Secrets or workflow requests.
class DartGithubTransport extends GithubTransport {
  final _active = <HttpClient>{};
  static const maxBytes = 1024 * 1024;

  static bool allows(Uri uri, {bool oauth = false}) {
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 443)) {
      return false;
    }
    if (oauth) {
      return uri.host == 'github.com' &&
          !uri.hasQuery &&
          const [
            '/login/device/code',
            '/login/oauth/access_token',
          ].contains(uri.path);
    }
    if (uri.host != 'api.github.com') return false;
    if (uri.path == '/user') return !uri.hasQuery;
    if (!RegExp(r'^/user/installations(?:/[1-9][0-9]*/repositories)?$')
        .hasMatch(uri.path)) {
      return false;
    }
    final q = uri.queryParametersAll;
    final page = int.tryParse(uri.queryParameters['page'] ?? '');
    return q.length == 2 &&
        q['per_page']?.length == 1 &&
        q['per_page']?.single == '100' &&
        q['page']?.length == 1 &&
        page != null &&
        page >= 1 &&
        page <= 10;
  }

  @override
  Future<GithubReply> send(
    Uri uri, {
    String? token,
    Map<String, String>? form,
  }) async {
    if (!allows(uri, oauth: form != null) ||
        (form != null && token != null) ||
        (form == null && !isGithubToken(token))) {
      throw const GithubFailure(GithubIssue.response);
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _active.add(client);
    Future<GithubReply> request() async {
      final req = await client.openUrl(form == null ? 'GET' : 'POST', uri);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'RainClientDevelopment/0.1');
      if (token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        req.headers.set('X-GitHub-Api-Version', '2026-03-10');
      }
      if (form != null) {
        req.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        req.write(Uri(queryParameters: form).query);
      }
      final response = await req.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const GithubFailure(GithubIssue.response);
        }
        bytes.addAll(chunk);
      }
      return GithubReply(response.statusCode, utf8.decode(bytes));
    }

    try {
      return await request().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          client.close(force: true);
          throw const GithubFailure(GithubIssue.timeout);
        },
      );
    } on GithubFailure {
      rethrow;
    } on Object {
      // Raw exceptions and remote error text can contain request details.
      throw const GithubFailure(GithubIssue.network);
    } finally {
      client.close(force: true);
      _active.remove(client);
    }
  }

  @override
  void cancelPending() {
    for (final client in _active.toList()) {
      client.close(force: true);
    }
    _active.clear();
  }
}

abstract class GithubGateway {
  Future<GithubDeviceGrant> startAuthorization();
  Future<GithubPoll> poll(GithubDeviceGrant grant);
  Future<GithubTokens> refresh(String refreshToken);
  Future<GithubAccount> inspect(String accessToken);
  void cancelPending() {}
}

class GithubClient extends GithubGateway {
  GithubClient({
    this.config = const GithubAppConfig(),
    GithubTransport? transport,
    DateTime Function()? now,
  }) : _transport = transport ?? DartGithubTransport(),
       _now = now ?? DateTime.now;

  final GithubAppConfig config;
  final GithubTransport _transport;
  final DateTime Function() _now;
  int _generation = 0;

  @override
  void cancelPending() {
    _generation++;
    _transport.cancelPending();
  }

  Future<Map<String, dynamic>> _json(
    Uri uri, {
    String? token,
    Map<String, String>? form,
  }) async {
    final r = await _transport.send(uri, token: token, form: form);
    if (r.status == 401) {
      throw const GithubFailure(GithubIssue.unauthorized);
    }
    if (r.status == 403 || r.status == 429) {
      throw const GithubFailure(GithubIssue.forbidden);
    }
    if (r.status != 200 || r.body.length > DartGithubTransport.maxBytes) {
      throw const GithubFailure(GithubIssue.response);
    }
    try {
      final body = jsonDecode(r.body);
      if (body is Map<String, dynamic>) return body;
    } on FormatException {
      // The UI receives a fixed category, never the raw reply.
    }
    throw const GithubFailure(GithubIssue.response);
  }

  @override
  Future<GithubDeviceGrant> startAuthorization() async {
    final d = await _json(
      Uri.https('github.com', '/login/device/code'),
      form: {'client_id': config.clientId, 'scope': 'offline_access'},
    );
    if (!isGithubToken(d['device_code']) ||
        d['user_code'] is! String ||
        !RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$').hasMatch(d['user_code']) ||
        d['verification_uri'] != GithubAppConfig.verificationUri.toString()) {
      throw const GithubFailure(GithubIssue.response);
    }
    final seconds = githubPositiveInt(d['expires_in'], max: 900);
    final interval = githubPositiveInt(d['interval'] ?? 5, max: 60);
    return GithubDeviceGrant(
      deviceCode: d['device_code'] as String,
      userCode: d['user_code'] as String,
      expiresAt: _now().add(Duration(seconds: seconds)),
      interval: Duration(seconds: interval < 5 ? 5 : interval),
    );
  }

  Future<Map<String, dynamic>> _exchange(Map<String, String> form) => _json(
    Uri.https('github.com', '/login/oauth/access_token'),
    form: {'client_id': config.clientId, ...form},
  );

  @override
  Future<GithubPoll> poll(GithubDeviceGrant grant) async {
    if (!_now().isBefore(grant.expiresAt)) {
      throw const GithubFailure(GithubIssue.expired);
    }
    final body = await _exchange({
      'device_code': grant.deviceCode,
      'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
    });
    switch (body['error']) {
      case 'authorization_pending':
        return const GithubPoll(GithubPollState.pending);
      case 'slow_down':
        return const GithubPoll(GithubPollState.slowDown);
      case 'access_denied':
        throw const GithubFailure(GithubIssue.denied);
      case 'expired_token':
        throw const GithubFailure(GithubIssue.expired);
      case null:
        return GithubPoll(
          GithubPollState.authorized,
          GithubTokens.fromExchange(body, _now()),
        );
      default:
        throw const GithubFailure(GithubIssue.response);
    }
  }

  @override
  Future<GithubTokens> refresh(String refreshToken) async {
    if (!isGithubToken(refreshToken)) {
      throw const GithubFailure(GithubIssue.unauthorized);
    }
    final body = await _exchange({
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
    });
    if (body['error'] != null) {
      throw const GithubFailure(GithubIssue.unauthorized);
    }
    return GithubTokens.fromExchange(body, _now());
  }

  Future<List<Map<String, dynamic>>> _pages(
    String path,
    String listKey,
    String token,
    int generation,
  ) async {
    final result = <Map<String, dynamic>>[];
    int? total;
    for (var page = 1; page <= 10; page++) {
      if (generation != _generation) {
        throw const GithubFailure(GithubIssue.network);
      }
      final body = await _json(
        Uri.https('api.github.com', path, {'per_page': '100', 'page': '$page'}),
        token: token,
      );
      if (generation != _generation) {
        throw const GithubFailure(GithubIssue.network);
      }
      final count = body['total_count'];
      final items = body[listKey];
      if (count is! int ||
          count < 0 ||
          count > 1000 ||
          (total != null && total != count) ||
          items is! List ||
          items.length > 100 ||
          items.any((item) => item is! Map<String, dynamic>)) {
        throw const GithubFailure(GithubIssue.response);
      }
      total = count;
      result.addAll(items.cast<Map<String, dynamic>>());
      if (result.length == total) return result;
      if (items.isEmpty || result.length > total) break;
    }
    throw const GithubFailure(GithubIssue.response);
  }

  @override
  Future<GithubAccount> inspect(String accessToken) async {
    final generation = _generation;
    final profile = await _json(
      Uri.https('api.github.com', '/user'),
      token: accessToken,
    );
    if (generation != _generation) {
      throw const GithubFailure(GithubIssue.network);
    }
    final userId = githubPositiveInt(profile['id']);
    final login = profile['login'];
    if (login is! String || login.toLowerCase() != config.owner.toLowerCase()) {
      throw const GithubFailure(GithubIssue.scope);
    }
    final installations = await _pages(
      '/user/installations',
      'installations',
      accessToken,
      generation,
    );
    final repositories = <int, GithubRepository>{};
    for (final install in installations.where(
      (i) => i['app_id'] == config.appId,
    )) {
      if (install['suspended_at'] != null) continue;
      final owner = install['account'];
      final permissions = install['permissions'];
      if (install['repository_selection'] != 'selected' ||
          owner is! Map ||
          owner['login'] != config.owner ||
          permissions is! Map ||
          permissions.length != GithubAppConfig.permissions.length ||
          GithubAppConfig.permissions.entries.any(
            (e) => permissions[e.key] != e.value,
          )) {
        throw const GithubFailure(GithubIssue.scope);
      }
      final id = githubPositiveInt(install['id']);
      final repos = await _pages(
        '/user/installations/$id/repositories',
        'repositories',
        accessToken,
        generation,
      );
      for (final repo in repos) {
        final repoId = githubPositiveInt(repo['id']);
        final name = repo['full_name'];
        if (name is! String ||
            !RegExp(r'^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$')
                .hasMatch(name) ||
            repo['private'] is! bool ||
            repo['archived'] is! bool) {
          throw const GithubFailure(GithubIssue.response);
        }
        repositories[repoId] = GithubRepository(
          id: repoId,
          fullName: name,
          isPrivate: repo['private'] as bool,
          archived: repo['archived'] as bool,
        );
      }
    }
    return GithubAccount(
      id: userId,
      login: login,
      repositories: List.unmodifiable(
        repositories.values.toList()
          ..sort((a, b) => a.fullName.compareTo(b.fullName)),
      ),
    );
  }
}
