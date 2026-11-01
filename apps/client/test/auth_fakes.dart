import 'dart:async';

import 'package:rainclient/auth/cookie_reader.dart';
import 'package:rainclient/auth/session_client.dart';
import 'package:rainclient/auth/session_store.dart';

class MemoryStore implements SessionStore {
  MemoryStore([this.value]);
  String? value;
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;
  bool failReady = false;
  int readyChecks = 0;
  Completer<String?>? readGate;
  Completer<void> readStarted = Completer<void>();
  Completer<void>? writeGate;
  final writeStarted = Completer<void>();

  @override
  Future<String?> read() async {
    if (failRead) throw StateError('synthetic read failure');
    if (readGate != null) {
      final gate = readGate!;
      readGate = null;
      if (!readStarted.isCompleted) readStarted.complete();
      return gate.future;
    }
    return value;
  }

  @override
  Future<void> write(String session) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    if (writeGate != null) await writeGate!.future;
    if (failWrite) throw StateError('synthetic write failure');
    value = session;
  }

  @override
  Future<void> delete() async {
    if (failDelete) throw StateError('synthetic delete failure');
    value = null;
  }

  @override
  Future<void> checkReady() async {
    readyChecks++;
    if (failReady) throw StateError('synthetic readiness failure');
  }
}

class MemoryCookies implements SessionCookieSource {
  String? candidate;
  bool failClear = false;
  int clearCount = 0;

  @override
  Future<String?> read() async => candidate;

  @override
  Future<void> clear() async {
    clearCount++;
    if (failClear) throw StateError('synthetic cookie cleanup failure');
    candidate = null;
  }
}

class FakeVerifier extends SessionVerifier {
  SessionCheck answer = const SessionCheck(
    SessionVerdict.valid,
    CheckIssue.none,
  );
  Completer<SessionCheck>? gate;
  final started = Completer<void>();
  int calls = 0;
  int cancellations = 0;

  @override
  Future<SessionCheck> verify(String session) async {
    calls++;
    if (!started.isCompleted) started.complete();
    return gate == null ? answer : gate!.future;
  }

  @override
  void cancelPending() => cancellations++;
}
