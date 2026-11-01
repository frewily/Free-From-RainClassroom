enum GithubIssue {
  network,
  timeout,
  response,
  unauthorized,
  forbidden,
  denied,
  expired,
  scope,
  storage,
}

class GithubFailure implements Exception {
  const GithubFailure(this.issue);
  final GithubIssue issue;
}

/// Public identifiers of the existing private development App, never a secret.
class GithubAppConfig {
  const GithubAppConfig({
    this.appId = 5504900,
    this.clientId = 'Iv23li36LZrIGh5lZQOR',
    this.name = 'Rain S0 Manager 20261028',
    this.owner = 'frewily',
  });

  final int appId;
  final String clientId;
  final String name;
  final String owner;
  static final verificationUri = Uri.https('github.com', '/login/device');
  static const permissions = {
    'actions': 'write',
    'administration': 'write',
    'contents': 'write',
    'metadata': 'read',
    'secrets': 'write',
    'workflows': 'write',
  };
}

bool isGithubToken(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9_-]{8,512}$').hasMatch(value);

int githubPositiveInt(Object? value, {int max = 9007199254740991}) {
  if (value is! int || value <= 0 || value > max) {
    throw const GithubFailure(GithubIssue.response);
  }
  return value;
}

class GithubDeviceGrant {
  const GithubDeviceGrant({
    required this.deviceCode,
    required this.userCode,
    required this.expiresAt,
    required this.interval,
  });
  final String deviceCode;
  final String userCode;
  final DateTime expiresAt;
  final Duration interval;
}

class GithubTokens {
  const GithubTokens({
    required this.access,
    required this.refresh,
    required this.expiresAt,
    required this.refreshExpiresAt,
  });

  factory GithubTokens.fromExchange(Map<String, dynamic> value, DateTime now) {
    if (!isGithubToken(value['access_token']) ||
        !isGithubToken(value['refresh_token']) ||
        value['token_type'] != 'bearer') {
      throw const GithubFailure(GithubIssue.response);
    }
    return GithubTokens(
      access: value['access_token'] as String,
      refresh: value['refresh_token'] as String,
      expiresAt: now.add(
        Duration(seconds: githubPositiveInt(value['expires_in'], max: 86400)),
      ),
      refreshExpiresAt: now.add(
        Duration(
          seconds: githubPositiveInt(
            value['refresh_token_expires_in'],
            max: 366 * 86400,
          ),
        ),
      ),
    );
  }

  factory GithubTokens.fromJson(Map<String, dynamic> value) {
    if (!isGithubToken(value['access']) || !isGithubToken(value['refresh'])) {
      throw const GithubFailure(GithubIssue.storage);
    }
    final expiry = DateTime.tryParse(value['expiresAt'] as String? ?? '');
    final refreshExpiry = DateTime.tryParse(
      value['refreshExpiresAt'] as String? ?? '',
    );
    if (expiry == null || refreshExpiry == null) {
      throw const GithubFailure(GithubIssue.storage);
    }
    return GithubTokens(
      access: value['access'] as String,
      refresh: value['refresh'] as String,
      expiresAt: expiry,
      refreshExpiresAt: refreshExpiry,
    );
  }

  final String access;
  final String refresh;
  final DateTime expiresAt;
  final DateTime refreshExpiresAt;

  Map<String, dynamic> toJson() => {
    'access': access,
    'refresh': refresh,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'refreshExpiresAt': refreshExpiresAt.toUtc().toIso8601String(),
  };
}

enum GithubPollState { pending, slowDown, authorized }

class GithubPoll {
  const GithubPoll(this.state, [this.tokens]);
  final GithubPollState state;
  final GithubTokens? tokens;
}

class GithubRepository {
  const GithubRepository({
    required this.id,
    required this.fullName,
    required this.isPrivate,
    required this.archived,
  });
  final int id;
  final String fullName;
  final bool isPrivate;
  final bool archived;
}

class GithubAccount {
  const GithubAccount({
    required this.id,
    required this.login,
    required this.repositories,
  });
  final int id;
  final String login;
  final List<GithubRepository> repositories;
}

class GithubSavedSession {
  const GithubSavedSession({
    required this.appId,
    required this.accountId,
    required this.tokens,
    this.selectedRepositoryId,
    this.refreshPending = false,
  });

  factory GithubSavedSession.fromJson(Map<String, dynamic> value) {
    final selected = value['selectedRepositoryId'];
    if (value['version'] != 1 ||
        value['tokens'] is! Map<String, dynamic> ||
        value['refreshPending'] is! bool ||
        (selected != null && (selected is! int || selected <= 0))) {
      throw const GithubFailure(GithubIssue.storage);
    }
    return GithubSavedSession(
      appId: githubPositiveInt(value['appId']),
      accountId: githubPositiveInt(value['accountId']),
      tokens: GithubTokens.fromJson(value['tokens'] as Map<String, dynamic>),
      selectedRepositoryId: selected as int?,
      refreshPending: value['refreshPending'] as bool,
    );
  }

  final int appId;
  final int accountId;
  final GithubTokens tokens;
  final int? selectedRepositoryId;
  final bool refreshPending;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'appId': appId,
    'accountId': accountId,
    'tokens': tokens.toJson(),
    'selectedRepositoryId': selectedRepositoryId,
    'refreshPending': refreshPending,
  };
}
