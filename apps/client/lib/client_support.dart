import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum ClientIssue {
  network,
  response,
  authorization,
  storage,
  cancelled,
  conflict,
}

class ClientFailure implements Exception {
  const ClientFailure(this.issue, {this.httpStatus, this.providerCode});
  final ClientIssue issue;
  final int? httpStatus;
  final int? providerCode;
}

class SerialWork {
  Future<void> _tail = Future<void>.value();
  Future<T> run<T>(Future<T> Function() action) {
    final task = _tail.then((_) => action());
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }
}

abstract interface class RecordStore {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
  Future<void> delete();
}

class SecureRecordStore implements RecordStore {
  SecureRecordStore(String namespace, this.key)
    : _storage = FlutterSecureStorage(
        aOptions: AndroidOptions(
          resetOnError: false,
          enforceBiometrics: false,
          storageNamespace: namespace,
        ),
      );
  final FlutterSecureStorage _storage;
  final String key;

  @override
  Future<Map<String, dynamic>?> read() async {
    final raw = await _storage.read(key: key);
    if (raw == null) return null;
    if (raw.length > 65536) throw const ClientFailure(ClientIssue.storage);
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) {
      throw const ClientFailure(ClientIssue.storage);
    }
    return value;
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    final raw = jsonEncode(value);
    await _storage.write(key: key, value: raw);
    if (await _storage.read(key: key) != raw) {
      throw const ClientFailure(ClientIssue.storage);
    }
  }

  @override
  Future<void> delete() async {
    await _storage.delete(key: key);
    if (await _storage.read(key: key) != null) {
      throw const ClientFailure(ClientIssue.storage);
    }
  }
}

class WireReply {
  const WireReply(this.status, this.body);
  final int status;
  final String body;
  Map<String, dynamic> json() {
    try {
      final value = jsonDecode(body);
      if (value is Map<String, dynamic>) return value;
    } on FormatException {
      /* Return only a safe category. */
    }
    throw const ClientFailure(ClientIssue.response);
  }
}

abstract class Wire {
  Future<WireReply> send(
    String method,
    Uri uri, {
    String? token,
    String? body,
    String contentType = 'application/json',
  });
  void cancel() {}
}

/// The caller supplies a resource-specific allowlist, checked before any I/O.
class HttpsWire extends Wire {
  HttpsWire(this.allows);
  final bool Function(String, Uri, bool) allows;
  final _active = <HttpClient>{};

  @override
  Future<WireReply> send(
    String method,
    Uri uri, {
    String? token,
    String? body,
    String contentType = 'application/json',
  }) async {
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 443) ||
        !allows(method, uri, token != null) ||
        (token != null && !RegExp(r'^[\x21-\x7e]{8,8192}$').hasMatch(token))) {
      throw const ClientFailure(ClientIssue.response);
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _active.add(client);
    Future<WireReply> perform() async {
      final request = await client.openUrl(method, uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'RainClientDevelopment/0.3',
      );
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (uri.host == 'api.github.com') {
        request.headers.set('X-GitHub-Api-Version', '2026-03-10');
      }
      if (body != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
        request.add(utf8.encode(body));
      }
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          throw const ClientFailure(ClientIssue.response);
        }
        bytes.addAll(chunk);
      }
      return WireReply(response.statusCode, utf8.decode(bytes));
    }

    try {
      return await perform().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          client.close(force: true);
          throw const ClientFailure(ClientIssue.network);
        },
      );
    } on ClientFailure {
      rethrow;
    } on Object {
      throw const ClientFailure(ClientIssue.network);
    } finally {
      client.close(force: true);
      _active.remove(client);
    }
  }

  @override
  void cancel() {
    for (final client in _active.toList()) {
      client.close(force: true);
    }
    _active.clear();
  }
}
