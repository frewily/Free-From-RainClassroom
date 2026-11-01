import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'github_models.dart';

abstract interface class GithubStore {
  Future<GithubSavedSession?> read();
  Future<void> write(GithubSavedSession session);
  Future<void> delete();
  Future<void> checkReady();
}

class SecureGithubStore implements GithubStore {
  SecureGithubStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              resetOnError: false,
              enforceBiometrics: false,
              storageNamespace: 'top.frewily.rainclient.dev.github.manager',
            ),
          );

  final FlutterSecureStorage _storage;
  static const _key = 'github.manager.v1';
  static const _marker = 'github.storage_check';

  @override
  Future<GithubSavedSession?> read() async {
    final text = await _storage.read(key: _key);
    if (text == null) return null;
    if (text.length > 16384) throw const GithubFailure(GithubIssue.storage);
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>) {
      throw const GithubFailure(GithubIssue.storage);
    }
    return GithubSavedSession.fromJson(value);
  }

  @override
  Future<void> write(GithubSavedSession session) async {
    final text = jsonEncode(session.toJson());
    await _storage.write(key: _key, value: text);
    if (await _storage.read(key: _key) != text) {
      throw const GithubFailure(GithubIssue.storage);
    }
  }

  @override
  Future<void> delete() async {
    await _storage.delete(key: _key);
    if (await _storage.read(key: _key) != null) {
      throw const GithubFailure(GithubIssue.storage);
    }
  }

  @override
  Future<void> checkReady() async {
    final value = 'storage-check-${DateTime.now().microsecondsSinceEpoch}';
    try {
      await _storage.write(key: _marker, value: value);
      if (await _storage.read(key: _marker) != value) {
        throw const GithubFailure(GithubIssue.storage);
      }
    } finally {
      await _storage.delete(key: _marker);
    }
  }
}
