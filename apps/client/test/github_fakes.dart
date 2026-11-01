import 'dart:async';

import 'package:rainclient/github/github_client.dart';
import 'package:rainclient/github/github_models.dart';
import 'package:rainclient/github/github_store.dart';

final githubTestNow = DateTime.utc(2026, 10, 29, 12);

GithubTokens syntheticGithubTokens({
  bool expired = false,
  String suffix = 'old',
}) => GithubTokens(
  access: 'synthetic_access_$suffix',
  refresh: 'synthetic_refresh_$suffix',
  expiresAt: githubTestNow.add(
    expired ? const Duration(seconds: -1) : const Duration(hours: 8),
  ),
  refreshExpiresAt: githubTestNow.add(const Duration(days: 100)),
);

GithubSavedSession syntheticGithubSaved({
  bool expired = false,
  bool pending = false,
  int? selected,
}) => GithubSavedSession(
  appId: 5504900,
  accountId: 1,
  tokens: syntheticGithubTokens(expired: expired),
  selectedRepositoryId: selected,
  refreshPending: pending,
);

const syntheticGithubRepository = GithubRepository(
  id: 101,
  fullName: 'frewily/rain-client-s0-target-20261027',
  isPrivate: false,
  archived: false,
);

class MemoryGithubStore implements GithubStore {
  MemoryGithubStore([this.value]);
  GithubSavedSession? value;
  Completer<void>? readGate;
  Completer<void>? writeGate;
  final readStarted = Completer<void>();
  final writeStarted = Completer<void>();
  final writes = <GithubSavedSession>[];
  int deletes = 0;
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;
  int? failWriteAt;

  @override
  Future<GithubSavedSession?> read() async {
    if (!readStarted.isCompleted) readStarted.complete();
    final captured = value;
    if (readGate != null) await readGate!.future;
    if (failRead) throw StateError('synthetic storage failure');
    return captured;
  }

  @override
  Future<void> write(GithubSavedSession session) async {
    writes.add(session);
    if (!writeStarted.isCompleted) writeStarted.complete();
    if (writeGate != null) await writeGate!.future;
    if (failWrite || writes.length == failWriteAt) {
      throw StateError('synthetic storage failure');
    }
    value = session;
  }

  @override
  Future<void> delete() async {
    deletes++;
    if (failDelete) throw StateError('synthetic storage failure');
    value = null;
  }

  @override
  Future<void> checkReady() async {}
}

class FakeGithubGateway extends GithubGateway {
  GithubDeviceGrant grant = GithubDeviceGrant(
    deviceCode: 'synthetic_device_code',
    userCode: 'ABCD-1234',
    expiresAt: githubTestNow.add(const Duration(minutes: 15)),
    interval: const Duration(seconds: 5),
  );
  GithubAccount account = const GithubAccount(
    id: 1,
    login: 'frewily',
    repositories: [syntheticGithubRepository],
  );
  GithubTokens nextTokens = syntheticGithubTokens(suffix: 'new');
  final polls = <GithubPoll>[];
  final inspectErrors = <GithubFailure>[];
  GithubFailure? refreshError;
  Completer<GithubDeviceGrant>? startGate;
  Completer<GithubPoll>? pollGate;
  Completer<GithubAccount>? inspectGate;
  final startStarted = Completer<void>();
  final pollStarted = Completer<void>();
  final inspectStarted = Completer<void>();
  int starts = 0;
  int pollCount = 0;
  int refreshes = 0;
  int cancellations = 0;
  final inspectedAccessTokens = <String>[];

  @override
  Future<GithubDeviceGrant> startAuthorization() async {
    starts++;
    if (!startStarted.isCompleted) startStarted.complete();
    return startGate == null ? grant : startGate!.future;
  }

  @override
  Future<GithubPoll> poll(GithubDeviceGrant grant) async {
    pollCount++;
    if (!pollStarted.isCompleted) pollStarted.complete();
    if (pollGate != null) return pollGate!.future;
    return polls.isEmpty
        ? GithubPoll(GithubPollState.authorized, nextTokens)
        : polls.removeAt(0);
  }

  @override
  Future<GithubTokens> refresh(String refreshToken) async {
    refreshes++;
    if (refreshError != null) throw refreshError!;
    return nextTokens;
  }

  @override
  Future<GithubAccount> inspect(String accessToken) async {
    inspectedAccessTokens.add(accessToken);
    if (!inspectStarted.isCompleted) inspectStarted.complete();
    if (inspectErrors.isNotEmpty) throw inspectErrors.removeAt(0);
    return inspectGate == null ? account : inspectGate!.future;
  }

  @override
  void cancelPending() => cancellations++;
}
