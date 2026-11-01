import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'session_cookie.dart';

enum SessionVerdict { valid, invalid, unavailable }

enum CheckIssue { none, expired, network, timeout, response }

class SessionCheck {
  const SessionCheck(this.verdict, this.issue, {this.httpStatus});

  final SessionVerdict verdict;
  final CheckIssue issue;
  final int? httpStatus;
}

abstract class SessionVerifier {
  Future<SessionCheck> verify(String session);
  void cancelPending() {}
}

class SessionReply {
  const SessionReply(this.status, this.body);

  final int status;
  final String body;
}

abstract class SessionTransport {
  Future<SessionReply> fetch(String session);
  void cancelPending() {}
}

/// Only this fixed, read-only origin receives the session cookie.
class DartSessionTransport extends SessionTransport {
  HttpClient? _active;
  static final endpoint = Uri.parse(
    'https://changjiang.yuketang.cn/v2/api/web/userinfo',
  );
  static const maxBytes = 256 * 1024;

  @override
  Future<SessionReply> fetch(String session) async {
    cancelPending();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _active = client;
    Future<SessionReply> request() async {
      final request = await client.getUrl(endpoint);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.cookieHeader, 'sessionid=$session');
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const FormatException('Response exceeds the allowed size');
        }
        bytes.addAll(chunk);
      }
      return SessionReply(response.statusCode, utf8.decode(bytes));
    }

    try {
      return await request().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          client.close(force: true);
          throw TimeoutException('Session check timed out');
        },
      );
    } finally {
      client.close(force: true);
      if (identical(_active, client)) _active = null;
    }
  }

  @override
  void cancelPending() {
    _active?.close(force: true);
    _active = null;
  }
}

class SessionClient extends SessionVerifier {
  SessionClient({SessionTransport? transport})
    : _transport = transport ?? DartSessionTransport();

  final SessionTransport _transport;

  @override
  void cancelPending() => _transport.cancelPending();

  @override
  Future<SessionCheck> verify(String session) async {
    if (!isSafeSessionValue(session)) {
      return const SessionCheck(
        SessionVerdict.unavailable,
        CheckIssue.response,
      );
    }
    try {
      return classify(await _transport.fetch(session));
    } on TimeoutException {
      return const SessionCheck(SessionVerdict.unavailable, CheckIssue.timeout);
    } on Object {
      // Do not surface transport exceptions: they may contain request details.
      return const SessionCheck(SessionVerdict.unavailable, CheckIssue.network);
    }
  }

  static SessionCheck classify(SessionReply reply) {
    SessionCheck unavailable() => SessionCheck(
      SessionVerdict.unavailable,
      CheckIssue.response,
      httpStatus: reply.status,
    );
    if (reply.body.length > DartSessionTransport.maxBytes) return unavailable();
    Object? decoded;
    try {
      decoded = jsonDecode(reply.body);
    } on FormatException {
      return unavailable();
    }
    if (decoded is! Map<String, dynamic>) return unavailable();
    final code = decoded['errcode'];
    // These codes were observed using approved no-session/invalid controls.
    if ([200, 401].contains(reply.status) && [401000, 401002].contains(code)) {
      return SessionCheck(
        SessionVerdict.invalid,
        CheckIssue.expired,
        httpStatus: reply.status,
      );
    }
    if (reply.status != 200 || (code != null && code != 0)) {
      return unavailable();
    }
    final records = decoded['data'];
    final hasIdentity =
        records is List &&
        records.any(
          (record) =>
              record is Map &&
              ((record['name'] is String &&
                      (record['name'] as String).trim().isNotEmpty) ||
                  record['id'] != null ||
                  record['user_id'] != null),
        );
    return hasIdentity
        ? const SessionCheck(
            SessionVerdict.valid,
            CheckIssue.none,
            httpStatus: 200,
          )
        : unavailable();
  }
}
