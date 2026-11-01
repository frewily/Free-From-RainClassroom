import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/github/github_controller.dart';
import 'package:rainclient/github/github_models.dart';

import 'github_fakes.dart';

class GithubHarness {
  GithubHarness({
    GithubSavedSession? saved,
    Duration ioTimeout = const Duration(seconds: 8),
    Duration apiTimeout = const Duration(seconds: 45),
  }) {
    store = MemoryGithubStore(saved);
    controller = GithubController(
      client: api,
      store: store,
      now: () => now,
      ioTimeout: ioTimeout,
      apiTimeout: apiTimeout,
      wait: (duration) async {
        waits.add(duration);
        now = now.add(duration);
      },
    );
  }
  DateTime now = githubTestNow;
  final api = FakeGithubGateway();
  late final MemoryGithubStore store;
  late final GithubController controller;
  final waits = <Duration>[];
}

void main() {
  late GithubHarness h;
  setUp(() => h = GithubHarness());
  tearDown(() => h.controller.dispose());

  test('authorization verifies identity and saves before connected without auto-select', () async {
    await h.controller.restore();
    expect(h.controller.phase, GithubPhase.unbound);
    await h.controller.authorize();
    expect(h.controller.phase, GithubPhase.connected);
    expect(h.controller.account!.login, 'frewily');
    expect(h.store.value!.tokens.access, 'synthetic_access_new');
    expect(h.controller.selectedRepositoryId, isNull);
    expect(h.controller.userCode, isNull);
  });

  test('slow down permanently increases polling interval', () async {
    await h.controller.restore();
    h.api.polls.addAll([
      const GithubPoll(GithubPollState.pending),
      const GithubPoll(GithubPollState.slowDown),
      GithubPoll(GithubPollState.authorized, h.api.nextTokens),
    ]);
    await h.controller.authorize();
    expect(h.waits.map((d) => d.inSeconds), [5, 5, 10]);
    expect(h.controller.phase, GithubPhase.connected);
  });

  test(
    'device expiry is bounded and no request is made after deadline',
    () async {
      await h.controller.restore();
      h.api.grant = GithubDeviceGrant(
        deviceCode: 'synthetic_device_code',
        userCode: 'ABCD-1234',
        expiresAt: githubTestNow.add(const Duration(seconds: 12)),
        interval: const Duration(seconds: 5),
      );
      h.api.polls.addAll(
        List.filled(10, const GithubPoll(GithubPollState.pending)),
      );
      await h.controller.authorize();
      expect(h.api.pollCount, 2);
      expect(h.waits.map((d) => d.inSeconds), [5, 5, 2]);
      expect(h.controller.phase, GithubPhase.unbound);
      expect(h.controller.userCode, isNull);
    },
  );

  test(
    'cancellation before code response discards late authorization data',
    () async {
      await h.controller.restore();
      h.api.startGate = Completer<GithubDeviceGrant>();
      final task = h.controller.authorize();
      await h.api.startStarted.future;
      h.controller.cancelAuthorization();
      h.api.startGate!.complete(h.api.grant);
      await task;
      expect(h.controller.phase, GithubPhase.unbound);
      expect(h.controller.userCode, isNull);
      expect(h.api.pollCount, 0);
      expect(h.store.writes, isEmpty);
    },
  );

  test('late successful poll cannot restore a cancelled connection', () async {
    await h.controller.restore();
    h.api.pollGate = Completer<GithubPoll>();
    final task = h.controller.authorize();
    await h.api.pollStarted.future;
    h.controller.cancelAuthorization();
    h.api.pollGate!.complete(
      GithubPoll(GithubPollState.authorized, h.api.nextTokens),
    );
    await task;
    expect(h.controller.phase, GithubPhase.unbound);
    expect(h.store.value, isNull);
    expect(h.api.inspectedAccessTokens, isEmpty);
  });

  test(
    'network failure preserves an existing connection and selected repository',
    () async {
      h.store.value = syntheticGithubSaved(selected: 101);
      h.api.inspectErrors.add(const GithubFailure(GithubIssue.network));
      await h.controller.restore();
      expect(h.controller.phase, GithubPhase.unavailable);
      expect(h.store.value!.selectedRepositoryId, 101);
      expect(h.store.deletes, 0);
      await h.controller.retry();
      expect(h.controller.phase, GithubPhase.connected);
      expect(h.api.refreshes, 0);
    },
  );

  test(
    'token refresh is preceded by a durable marker and saves both new tokens',
    () async {
      h.store.value = syntheticGithubSaved(expired: true, selected: 101);
      await h.controller.restore();
      expect(h.api.refreshes, 1);
      expect(h.store.writes.length, 2);
      expect(h.store.writes.first.refreshPending, isTrue);
      expect(h.store.value!.refreshPending, isFalse);
      expect(h.store.value!.tokens.refresh, 'synthetic_refresh_new');
      expect(h.api.inspectedAccessTokens, ['synthetic_access_new']);
      expect(h.controller.selectedRepositoryId, 101);
    },
  );

  test(
    'unknown rotating-refresh result is not retried after reopening',
    () async {
      h.store.value = syntheticGithubSaved(expired: true);
      h.api.refreshError = const GithubFailure(GithubIssue.network);
      await h.controller.restore();
      expect(h.store.value!.refreshPending, isTrue);
      expect(h.controller.phase, GithubPhase.needsAuthorization);
      await h.controller.retry();
      expect(h.api.refreshes, 1);
      expect(h.api.inspectedAccessTokens, isEmpty);
    },
  );

  test(
    'failure saving rotated pair cannot replay old refresh credential',
    () async {
      h.store.value = syntheticGithubSaved(expired: true);
      h.store.failWriteAt = 2;
      await h.controller.restore();
      expect(h.controller.phase, GithubPhase.needsAuthorization);
      expect(h.store.value!.refreshPending, isTrue);
      await h.controller.retry();
      expect(h.api.refreshes, 1);
    },
  );

  test('unexpected 401 triggers at most one refresh before requesting new authorization', () async {
    h.store.value = syntheticGithubSaved();
    h.api.inspectErrors.addAll([
      const GithubFailure(GithubIssue.unauthorized),
      const GithubFailure(GithubIssue.unauthorized),
    ]);
    await h.controller.restore();
    expect(h.api.refreshes, 1);
    expect(h.api.inspectedAccessTokens.length, 2);
    expect(h.controller.phase, GithubPhase.needsAuthorization);
  });

  test(
    'removed repository selection is cleared and another is not auto-selected',
    () async {
      h.store.value = syntheticGithubSaved(selected: 101);
      h.api.account = const GithubAccount(
        id: 1,
        login: 'frewily',
        repositories: [
          GithubRepository(
            id: 202,
            fullName: 'frewily/other',
            isPrivate: true,
            archived: false,
          ),
        ],
      );
      await h.controller.restore();
      expect(h.controller.phase, GithubPhase.connected);
      expect(h.store.value!.selectedRepositoryId, isNull);
      expect(h.controller.selectedRepositoryId, isNull);
    },
  );

  test('selection only accepts currently listed usable repositories', () async {
    h.store.value = syntheticGithubSaved();
    await h.controller.restore();
    await h.controller.selectRepository(999);
    expect(h.store.writes, isEmpty);
    await h.controller.selectRepository(101);
    expect(h.controller.selectedRepositoryId, 101);
    expect(h.store.value!.selectedRepositoryId, 101);
    expect(h.api.inspectedAccessTokens.length, 1);
  });

  test(
    'saving authorization failure stays retryable without another device flow',
    () async {
      await h.controller.restore();
      h.store.failWrite = true;
      await h.controller.authorize();
      expect(h.controller.phase, GithubPhase.error);
      h.store.failWrite = false;
      await h.controller.retry();
      expect(h.controller.phase, GithubPhase.connected);
      expect(h.api.starts, 1);
      expect(h.api.pollCount, 1);
    },
  );

  test(
    'late account response after disconnect cannot write credentials',
    () async {
      await h.controller.restore();
      h.api.inspectGate = Completer<GithubAccount>();
      final auth = h.controller.authorize();
      await h.api.inspectStarted.future;
      await h.controller.disconnect();
      h.api.inspectGate!.complete(h.api.account);
      await auth;
      expect(h.store.value, isNull);
      expect(h.controller.phase, GithubPhase.unbound);
      expect(h.store.writes, isEmpty);
    },
  );

  test('physical save finishes before queued disconnect deletes it', () async {
    await h.controller.restore();
    h.store.writeGate = Completer<void>();
    final auth = h.controller.authorize();
    await h.store.writeStarted.future;
    final disconnect = h.controller.disconnect();
    h.store.writeGate!.complete();
    await Future.wait([auth, disconnect]);
    expect(h.store.value, isNull);
    expect(h.controller.account, isNull);
    expect(h.controller.phase, GithubPhase.unbound);
  });

  test(
    'timed-out storage does not let disconnect bypass a late save',
    () async {
      h.controller.dispose();
      h = GithubHarness(ioTimeout: const Duration(milliseconds: 15));
      await h.controller.restore();
      h.store.writeGate = Completer<void>();
      await h.controller.authorize();
      expect(h.controller.phase, GithubPhase.error);
      await h.controller.disconnect();
      expect(h.controller.phase, GithubPhase.error);
      expect(h.controller.canAuthorize, isFalse);
      h.store.writeGate!.complete();
      await h.controller.retry();
      expect(h.store.value, isNull);
      expect(h.controller.phase, GithubPhase.unbound);
    },
  );

  test(
    'late stored read after disconnect cannot resurrect old connection',
    () async {
      h.store.value = syntheticGithubSaved();
      h.store.readGate = Completer<void>();
      final restore = h.controller.restore();
      await h.store.readStarted.future;
      final disconnect = h.controller.disconnect();
      h.store.readGate!.complete();
      await Future.wait([restore, disconnect]);
      expect(h.store.value, isNull);
      expect(h.controller.account, isNull);
      expect(h.api.inspectedAccessTokens, isEmpty);
      expect(h.controller.phase, GithubPhase.unbound);
    },
  );

  test(
    'failed local deletion stays sticky until it really completes',
    () async {
      h.store.value = syntheticGithubSaved();
      await h.controller.restore();
      h.store.failDelete = true;
      await h.controller.disconnect();
      expect(h.controller.phase, GithubPhase.error);
      expect(h.controller.canAuthorize, isFalse);
      h.store.failDelete = false;
      await h.controller.retry();
      expect(h.controller.phase, GithubPhase.unbound);
      expect(h.store.value, isNull);
    },
  );

  test(
    'account identity mismatch after refresh never replaces saved identity',
    () async {
      h.store.value = syntheticGithubSaved();
      h.api.account = const GithubAccount(
        id: 999,
        login: 'frewily',
        repositories: [],
      );
      await h.controller.restore();
      expect(h.controller.phase, GithubPhase.unavailable);
      expect(h.store.value!.accountId, 1);
    },
  );

  test(
    'overall inspection deadline cancels the client and keeps local record',
    () async {
      h.controller.dispose();
      h = GithubHarness(
        saved: syntheticGithubSaved(),
        apiTimeout: const Duration(milliseconds: 15),
      );
      h.api.inspectGate = Completer<GithubAccount>();
      await h.controller.restore();
      expect(h.controller.phase, GithubPhase.unavailable);
      expect(h.api.cancellations, greaterThanOrEqualTo(2));
      expect(h.store.value, isNotNull);
      h.api.inspectGate!.complete(h.api.account);
    },
  );

  test('a stale deadline cannot cancel a newer operation', () async {
    h.controller.dispose();
    h = GithubHarness(
      saved: syntheticGithubSaved(),
      apiTimeout: const Duration(milliseconds: 15),
    );
    h.api.inspectGate = Completer<GithubAccount>();
    final oldRestore = h.controller.restore();
    await h.api.inspectStarted.future;
    await h.controller.disconnect();
    final cancellations = h.api.cancellations;
    await oldRestore;
    expect(h.api.cancellations, cancellations);
    expect(h.controller.phase, GithubPhase.unbound);
    h.api.inspectGate!.complete(h.api.account);
  });
}
