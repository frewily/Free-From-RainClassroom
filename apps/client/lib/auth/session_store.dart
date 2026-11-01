import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'session_cookie.dart';

class SessionStoreException implements Exception {
  const SessionStoreException();
}

abstract interface class SessionStore {
  Future<String?> read();
  Future<void> write(String session);
  Future<void> delete();
  Future<void> checkReady();
}

class SecureSessionStore implements SessionStore {
  SecureSessionStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              resetOnError: false,
              enforceBiometrics: false,
              storageNamespace: 'top.frewily.rainclient.dev.rainclass',
            ),
          );

  final FlutterSecureStorage _storage;
  static const _key = 'rainclass.session.v1';
  static const _probeKey = 'rainclass.storage_check';

  @override
  Future<String?> read() async {
    final value = await _storage.read(key: _key);
    if (value != null && !isSafeSessionValue(value)) {
      throw const SessionStoreException();
    }
    return value;
  }

  @override
  Future<void> write(String session) async {
    if (!isSafeSessionValue(session)) throw const SessionStoreException();
    await _storage.write(key: _key, value: session);
    if (await _storage.read(key: _key) != session) {
      throw const SessionStoreException();
    }
  }

  @override
  Future<void> delete() async {
    await _storage.delete(key: _key);
    if (await _storage.read(key: _key) != null) {
      throw const SessionStoreException();
    }
  }

  @override
  Future<void> checkReady() async {
    final marker = 'storage-check-${DateTime.now().microsecondsSinceEpoch}';
    try {
      await _storage.write(key: _probeKey, value: marker);
      if (await _storage.read(key: _probeKey) != marker) {
        throw const SessionStoreException();
      }
    } finally {
      await _storage.delete(key: _probeKey);
    }
  }
}
