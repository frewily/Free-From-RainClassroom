import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/auth/session_client.dart';
import 'package:rainclient/auth/session_controller.dart';

import 'auth_fakes.dart';

void main() {
  late MemoryStore store;
  late MemoryCookies cookies;
  late FakeVerifier verifier;
  late SessionController controller;

  setUp(() {
    store = MemoryStore();
    cookies = MemoryCookies();
    verifier = FakeVerifier();
    controller = SessionController(
      store: store,
      verifier: verifier,
      cookies: cookies,
    );
  });
  tearDown(() => controller.dispose());

  test(
    'fresh startup verifies local storage and stays logged out without network',
    () async {
      await controller.restore();
      expect(controller.phase, LoginPhase.loggedOut);
      expect(store.readyChecks, 1);
      expect(verifier.calls, 0);
    },
  );

  test(
    'restoring a saved session still requires a successful read-only check',
    () async {
      store.value = 'previous_session';
      await controller.restore();
      expect(controller.phase, LoginPhase.loggedIn);
      expect(controller.hasSavedSession, isTrue);
    },
  );

  test('temporary network failure preserves the saved session', () async {
    store.value = 'previous_session';
    verifier.answer = const SessionCheck(
      SessionVerdict.unavailable,
      CheckIssue.network,
    );
    await controller.restore();
    expect(controller.phase, LoginPhase.unavailable);
    expect(store.value, 'previous_session');
    verifier.answer = const SessionCheck(SessionVerdict.valid, CheckIssue.none);
    await controller.retry();
    expect(controller.phase, LoginPhase.loggedIn);
  });

  test('an explicit expired session is removed and requests relogin', () async {
    store.value = 'expired_session';
    verifier.answer = const SessionCheck(
      SessionVerdict.invalid,
      CheckIssue.expired,
    );
    await controller.restore();
    expect(controller.phase, LoginPhase.needsLogin);
    expect(store.value, isNull);
  });

  test(
    'a new candidate is saved only after verification and cookie cleanup',
    () async {
      await controller.restore();
      await controller.beginLogin();
      cookies.candidate = 'new_session';
      expect(await controller.checkLogin(), isTrue);
      expect(store.value, 'new_session');
      expect(cookies.candidate, isNull);
      expect(controller.phase, LoginPhase.loggedIn);
    },
  );

  test(
    'an invalid new login never replaces the previous saved session',
    () async {
      store.value = 'previous_session';
      await controller.restore();
      await controller.beginLogin();
      cookies.candidate = 'invalid_new_session';
      verifier.answer = const SessionCheck(
        SessionVerdict.invalid,
        CheckIssue.expired,
      );
      expect(await controller.checkLogin(), isFalse);
      expect(store.value, 'previous_session');
      verifier.answer = const SessionCheck(
        SessionVerdict.valid,
        CheckIssue.none,
      );
      await controller.cancelLogin();
      expect(controller.phase, LoginPhase.loggedIn);
      expect(store.value, 'previous_session');
    },
  );

  test(
    'a failed save is not reported as logged in and can be retried',
    () async {
      await controller.restore();
      await controller.beginLogin();
      cookies.candidate = 'new_session';
      store.failWrite = true;
      expect(await controller.checkLogin(), isFalse);
      expect(controller.phase, LoginPhase.error);
      store.failWrite = false;
      await controller.retry();
      expect(controller.phase, LoginPhase.loggedIn);
    },
  );

  test('a verification completing after logout cannot restore login', () async {
    await controller.restore();
    await controller.beginLogin();
    cookies.candidate = 'new_session';
    verifier.gate = Completer<SessionCheck>();
    final pending = controller.checkLogin();
    await verifier.started.future;
    await controller.logout();
    verifier.gate!.complete(
      const SessionCheck(SessionVerdict.valid, CheckIssue.none),
    );
    await pending;
    expect(controller.phase, LoginPhase.loggedOut);
    expect(store.value, isNull);
  });

  test('logout deletes after an already-running save finishes', () async {
    await controller.restore();
    await controller.beginLogin();
    cookies.candidate = 'new_session';
    store.writeGate = Completer<void>();
    final saving = controller.checkLogin();
    await store.writeStarted.future;
    final logout = controller.logout();
    store.writeGate!.complete();
    await Future.wait([saving, logout]);
    expect(store.value, isNull);
    expect(controller.phase, LoginPhase.loggedOut);
  });

  test(
    'cancel rolls back an in-flight replacement to the previous saved value',
    () async {
      store.value = 'previous_session';
      await controller.restore();
      await controller.beginLogin();
      cookies.candidate = 'new_session';
      store.writeGate = Completer<void>();
      final saving = controller.checkLogin();
      await store.writeStarted.future;
      final cancelled = controller.cancelLogin();
      store.writeGate!.complete();
      await Future.wait([saving, cancelled]);
      expect(store.value, 'previous_session');
      expect(controller.phase, LoginPhase.loggedIn);
    },
  );

  test(
    'logout still clears encrypted storage if cookie cleanup fails',
    () async {
      store.value = 'previous_session';
      await controller.restore();
      cookies.failClear = true;
      await controller.logout();
      expect(store.value, isNull);
      expect(controller.phase, LoginPhase.error);
      cookies.failClear = false;
      await controller.retry();
      expect(controller.phase, LoginPhase.loggedOut);
    },
  );

  test(
    'failed logout retries clearing instead of silently restoring the account',
    () async {
      store.value = 'previous_session';
      await controller.restore();
      store.failDelete = true;
      await controller.logout();
      expect(controller.phase, LoginPhase.error);
      store.failDelete = false;
      final calls = verifier.calls;
      await controller.restore();
      expect(store.value, isNull);
      expect(controller.phase, LoginPhase.loggedOut);
      expect(verifier.calls, calls);
    },
  );

  test(
    'unavailable secure storage is visible before entering official login',
    () async {
      store.failReady = true;
      await controller.restore();
      expect(controller.phase, LoginPhase.error);
    },
  );

  test(
    'a delayed login-start read cannot make a late cancel resurrect logout',
    () async {
      store.value = 'previous_session';
      await controller.restore();
      final readGate = Completer<String?>();
      store.readGate = readGate;
      final opening = controller.beginLogin();
      await store.readStarted.future;
      final loggingOut = controller.logout();
      readGate.complete('previous_session');
      await Future.wait([opening, loggingOut]);
      await controller.cancelLogin();
      expect(store.value, isNull);
      expect(controller.phase, LoginPhase.loggedOut);
    },
  );

  test('storage timeout reports an error while logout stays ordered after the late write', () async {
    controller.dispose();
    controller = SessionController(
      store: store,
      verifier: verifier,
      cookies: cookies,
      ioTimeout: const Duration(milliseconds: 10),
    );
    await controller.restore();
    await controller.beginLogin();
    cookies.candidate = 'new_session';
    store.writeGate = Completer<void>();
    final saving = controller.checkLogin();
    await store.writeStarted.future;
    expect(await saving, isFalse);
    expect(controller.phase, LoginPhase.error);
    await controller.logout();
    expect(controller.phase, LoginPhase.error);
    store.writeGate!.complete();
    await controller.retry();
    expect(store.value, isNull);
    expect(controller.phase, LoginPhase.loggedOut);
  });
}
