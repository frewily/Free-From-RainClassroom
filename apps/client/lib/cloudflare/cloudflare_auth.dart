import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../client_support.dart';
import 'cloudflare_return_guard.dart';

class CloudConfig {
  static const clientId = '840b60304c633c313f931fc8697f22f3';
  static const name = 'Rain S0 Cloud Manager 20261028';
  static const accountId = '6081b0f279a7de585cd27b877f1f5335';
  static final redirect = Uri.parse(
    'http://127.0.0.1:8765/cloudflare/callback',
  );
  static const scopes = [
    'd1.write',
    'workers-scripts.admin',
    'workers-kv-storage.write',
    'memberships.read',
    'user-details.read',
  ];
}

String secureNonce([int bytes = 32]) {
  final random = Random.secure();
  return base64Url
      .encode(List.generate(bytes, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

class CloudPkce {
  CloudPkce({String? verifier, String? state})
    : verifier = verifier ?? secureNonce(),
      state = state ?? secureNonce();
  final String verifier;
  final String state;
  String get challenge => base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');
  Uri get authorization => Uri.https('dash.cloudflare.com', '/oauth2/auth', {
    'client_id': CloudConfig.clientId,
    'response_type': 'code',
    'redirect_uri': CloudConfig.redirect.toString(),
    'scope': CloudConfig.scopes.join(' '),
    'state': state,
    'code_challenge': challenge,
    'code_challenge_method': 'S256',
  });

  String? callbackCode(Uri uri) {
    if (uri.path != CloudConfig.redirect.path ||
        uri.query.length > 4096 ||
        uri.queryParametersAll['state']?.length != 1 ||
        uri.queryParameters['state'] != state) {
      return null;
    }
    if (uri.queryParameters['error'] != null) {
      throw const ClientFailure(ClientIssue.authorization);
    }
    final codes = uri.queryParametersAll['code'];
    if (codes?.length != 1 ||
        !RegExp(r'^[\x21-\x7e]{1,2048}$').hasMatch(codes!.single)) {
      return null;
    }
    return codes.single;
  }
}

abstract class CloudCallback {
  Future<void> start(CloudPkce pkce);
  Future<String> get code;
  Future<void> close();
}

class LoopbackCloudCallback extends CloudCallback {
  LoopbackCloudCallback({this.port = 8765, AuthReturnGuard? guard})
    : _guard = guard ?? PlatformAuthReturnGuard() {
    unawaited(
      _code.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }
  HttpServer? _server;
  final AuthReturnGuard _guard;
  final int port;
  int get boundPort => _server!.port;
  final _code = Completer<String>();
  bool _used = false;
  bool _closed = false;
  Timer? _expiry;

  @override
  Future<String> get code => _code.future;

  @override
  Future<void> start(CloudPkce pkce) async {
    // Both the background guard and bind must succeed before opening a browser.
    late final HttpServer server;
    try {
      await _guard.start();
      if (_closed) throw const ClientFailure(ClientIssue.cancelled);
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
    } on Object {
      await _guard.stop();
      rethrow;
    }
    if (_closed) {
      await server.close(force: true);
      await _guard.stop();
      throw const ClientFailure(ClientIssue.cancelled);
    }
    _server = server;
    _server!.idleTimeout = const Duration(seconds: 5);
    _expiry = Timer(const Duration(minutes: 10), () {
      if (!_code.isCompleted) {
        _code.completeError(const ClientFailure(ClientIssue.authorization));
      }
      unawaited(close());
    });
    _server!.listen((request) async {
      final response = request.response;
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('Referrer-Policy', 'no-referrer');
      response.headers.set(
        'Content-Security-Policy',
        "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-return'; base-uri 'none'; form-action 'none'",
      );
      try {
        if (request.method != 'GET' ||
            request.headers.value('host') != '127.0.0.1:${server.port}' ||
            request.uri.path != CloudConfig.redirect.path) {
          response.statusCode = 404;
          await response.close();
          return;
        }
        if (_used) {
          response.headers.contentType = ContentType.html;
          response.write(_page);
          await response.close();
          return;
        }
        final code = pkce.callbackCode(request.uri);
        if (code == null) {
          response.statusCode = 403;
          await response.close();
          return;
        }
        _used = true;
        response.headers.contentType = ContentType.html;
        response.write(_page);
        await response.close();
        if (!_code.isCompleted) _code.complete(code);
      } on Object {
        response.statusCode = 400;
        await response.close();
        if (!_code.isCompleted) {
          _code.completeError(const ClientFailure(ClientIssue.authorization));
        }
      }
    });
  }

  static const _page =
      '''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>返回雨课堂管理</title></head><body style="font:18px system-ui;padding:32px;line-height:1.8"><h2>已收到授权结果</h2><p>请返回雨课堂管理应用，查看账号验证结果。</p><script nonce="return">history.replaceState(null,'','/cloudflare/complete');</script></body></html>''';

  @override
  Future<void> close() async {
    _closed = true;
    _expiry?.cancel();
    final server = _server;
    _server = null;
    if (!_code.isCompleted) {
      _code.completeError(const ClientFailure(ClientIssue.cancelled));
    }
    try {
      await server?.close(force: true);
    } finally {
      await _guard.stop();
    }
  }
}

class CloudSession {
  const CloudSession({
    required this.token,
    required this.userId,
    required this.accountName,
    this.expiresAt,
  });
  final String token;
  final String userId;
  final String accountName;
  final DateTime? expiresAt;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'token': token,
    'userId': userId,
    'accountId': CloudConfig.accountId,
    'accountName': accountName,
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
  };
  factory CloudSession.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        json['accountId'] != CloudConfig.accountId ||
        json['token'] is! String ||
        !RegExp(r'^[\x21-\x7e]{8,8192}$').hasMatch(json['token']) ||
        json['userId'] is! String ||
        json['accountName'] is! String) {
      throw const ClientFailure(ClientIssue.storage);
    }
    final expiry = json['expiresAt'];
    if (expiry != null &&
        (expiry is! String || DateTime.tryParse(expiry) == null)) {
      throw const ClientFailure(ClientIssue.storage);
    }
    return CloudSession(
      token: json['token'],
      userId: json['userId'],
      accountName: json['accountName'],
      expiresAt: expiry == null ? null : DateTime.parse(expiry),
    );
  }
}

abstract class CloudGateway {
  Future<CloudSession> exchange(String code, CloudPkce pkce);
  Future<CloudSession> inspect(CloudSession session);
  void cancel() {}
}

class CloudClient extends CloudGateway {
  CloudClient({Wire? wire, DateTime Function()? now})
    : wire = wire ?? HttpsWire(allows),
      now = now ?? DateTime.now;
  final Wire wire;
  final DateTime Function() now;
  int _generation = 0;
  static bool allows(String method, Uri uri, bool credential) {
    if (method == 'POST' &&
        uri.host == 'dash.cloudflare.com' &&
        uri.path == '/oauth2/token' &&
        !uri.hasQuery &&
        !credential) {
      return true;
    }
    if (method != 'GET' || uri.host != 'api.cloudflare.com' || !credential) {
      return false;
    }
    if (uri.path == '/client/v4/user') return !uri.hasQuery;
    final page = int.tryParse(uri.queryParameters['page'] ?? '');
    return uri.path == '/client/v4/memberships' &&
        uri.queryParametersAll.length == 2 &&
        uri.queryParametersAll.values.every((values) => values.length == 1) &&
        uri.queryParameters['per_page'] == '50' &&
        page != null &&
        page >= 1 &&
        page <= 10;
  }

  @override
  void cancel() {
    _generation++;
    wire.cancel();
  }

  Future<Object?> _result(
    String path,
    String token, [
    Map<String, String>? query,
  ]) async {
    final response = await wire.send(
      'GET',
      Uri.https('api.cloudflare.com', '/client/v4$path', query),
      token: token,
    );
    if (response.status == 401) {
      throw const ClientFailure(ClientIssue.authorization);
    }
    final body = response.json();
    if (response.status != 200 || body['success'] != true) {
      throw const ClientFailure(ClientIssue.network);
    }
    return body['result'];
  }

  @override
  Future<CloudSession> exchange(String code, CloudPkce pkce) async {
    final response = await wire.send(
      'POST',
      Uri.https('dash.cloudflare.com', '/oauth2/token'),
      body: Uri(
        queryParameters: {
          'client_id': CloudConfig.clientId,
          'code': code,
          'grant_type': 'authorization_code',
          'redirect_uri': CloudConfig.redirect.toString(),
          'code_verifier': pkce.verifier,
        },
      ).query,
      contentType: 'application/x-www-form-urlencoded',
    );
    if (response.status != 200) {
      throw const ClientFailure(ClientIssue.authorization);
    }
    final body = response.json();
    final token = body['access_token'];
    final scopes = body['scope'] is String
        ? (body['scope'] as String).split(RegExp(r'\s+')).toSet()
        : <String>{};
    if (token is! String ||
        !RegExp(r'^[\x21-\x7e]{8,8192}$').hasMatch(token) ||
        scopes.length != CloudConfig.scopes.length ||
        !scopes.containsAll(CloudConfig.scopes)) {
      throw const ClientFailure(ClientIssue.authorization);
    }
    final seconds = body['expires_in'];
    if (seconds != null &&
        (seconds is! int || seconds <= 0 || seconds > 366 * 86400)) {
      throw const ClientFailure(ClientIssue.response);
    }
    return CloudSession(
      token: token,
      userId: '',
      accountName: '',
      expiresAt: seconds == null
          ? null
          : now().add(Duration(seconds: seconds as int)),
    );
  }

  @override
  Future<CloudSession> inspect(CloudSession session) async {
    final generation = _generation;
    if (session.expiresAt != null && !now().isBefore(session.expiresAt!)) {
      throw const ClientFailure(ClientIssue.authorization);
    }
    final user = await _result('/user', session.token);
    if (generation != _generation) {
      throw const ClientFailure(ClientIssue.cancelled);
    }
    if (user is! Map ||
        user['id'] is! String ||
        (user['id'] as String).isEmpty ||
        session.userId.isNotEmpty && user['id'] != session.userId) {
      throw const ClientFailure(ClientIssue.authorization);
    }
    String? accountName;
    for (var page = 1; page <= 10; page++) {
      final members = await _result('/memberships', session.token, {
        'per_page': '50',
        'page': '$page',
      });
      if (generation != _generation) {
        throw const ClientFailure(ClientIssue.cancelled);
      }
      if (members is! List || members.length > 50) {
        throw const ClientFailure(ClientIssue.response);
      }
      for (final member in members) {
        if (member is Map &&
            member['status'] == 'accepted' &&
            member['account'] is Map &&
            member['account']['id'] == CloudConfig.accountId) {
          final name = member['account']['name'];
          accountName = name is String && name.isNotEmpty
              ? name
              : 'Cloudflare 账号';
        }
      }
      if (accountName != null || members.length < 50) break;
    }
    if (accountName == null) {
      throw const ClientFailure(ClientIssue.authorization);
    }
    return CloudSession(
      token: session.token,
      userId: user['id'],
      accountName: accountName,
      expiresAt: session.expiresAt,
    );
  }
}
