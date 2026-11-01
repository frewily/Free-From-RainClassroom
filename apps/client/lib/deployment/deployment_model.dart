import 'dart:convert';
import 'dart:math';

import '../client_support.dart';
import '../cloudflare/cloudflare_auth.dart';

const deploymentRepository = 'frewily/rain-client-s0-target-20261027';
const workerSource = '''export default {
  async fetch(request, env) {
    if (request.method !== "GET" || new URL(request.url).pathname !== "/health")
      return new Response("Not found", {status: 404});
    return Response.json({ok: true, kind: "rain-client-synthetic-v1", instance: env.INSTANCE});
  }
};''';
const closedWorkerSource =
    '''export default {fetch() {return new Response("Not found", {status:404});}};''';

class DeploymentPlan {
  DeploymentPlan(this.nonce, {this.workflowRevision = 2}) {
    if (!RegExp(r'^[a-f0-9]{16}$').hasMatch(nonce) ||
        ![1, 2].contains(workflowRevision)) {
      throw const ClientFailure(ClientIssue.storage);
    }
  }
  factory DeploymentPlan.create() {
    final r = Random.secure();
    return DeploymentPlan(
      List.generate(
        8,
        (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
    );
  }
  final String nonce;
  final int workflowRevision;
  String get worker => 'rain-client-dev-$nonce';
  String get filename => 'rain-client-dev-$nonce.yml';
  String get workflow => '.github/workflows/$filename';
  String get title => 'Rain client dev $nonce';
  String get cfBase => '/client/v4/accounts/${CloudConfig.accountId}';
  String get ghBase => '/repos/$deploymentRepository';
  String get scriptPath => '$cfBase/workers/scripts/$worker';

  bool validHost(String host) =>
      RegExp('^${RegExp.escape(worker)}\\.[a-z0-9-]{1,63}\\.workers\\.dev\$')
          .hasMatch(host);

  String workflowSource(String host) {
    if (!validHost(host)) throw const ClientFailure(ClientIssue.response);
    // Retain the exact source for older persisted plans so cleanup can verify it.
    final requestSource = workflowRevision == 1
        ? "          with urllib.request.urlopen(os.environ['HEALTH_URL'], timeout=20) as reply:"
        : '''          request = urllib.request.Request(
              os.environ['HEALTH_URL'],
              headers={'User-Agent': 'RainClient-Deployment-Probe/1.0'},
          )
          with urllib.request.urlopen(request, timeout=20) as reply:''';
    return '''name: $title
run-name: $title
on: workflow_dispatch
permissions: {}
jobs:
  verify:
    runs-on: ubuntu-latest
    timeout-minutes: 3
    steps:
      - name: Verify synthetic Cloudflare environment
        env:
          HEALTH_URL: ${jsonEncode('https://$host/health')}
          EXPECTED_INSTANCE: ${jsonEncode(nonce)}
        run: |
          python3 - <<'PY'
          import json, os, urllib.request
$requestSource
              raw = reply.read(4097)
          if len(raw) > 4096:
              raise SystemExit('Unexpected response size')
          data = json.loads(raw)
          if data.get('ok') is not True or data.get('kind') != 'rain-client-synthetic-v1' or data.get('instance') != os.environ['EXPECTED_INSTANCE']:
              raise SystemExit('Synthetic environment verification failed')
          print('Rain client synthetic environment verified')
          PY
''';
  }
}

class DeploymentRecord {
  DeploymentRecord({
    required this.plan,
    required this.repositoryId,
    required this.userId,
  });
  final DeploymentPlan plan;
  final int repositoryId, userId;
  String stage = 'prepared';
  String? host, headSha;
  int? runId;
  String runStatus = 'not_started';
  String? conclusion;
  bool workerAttempt = false, workflowAttempt = false, dispatchAttempt = false;
  bool? phoneHealthReachable;
  bool entryClosed = false, cleaned = false, workerClearAttempt = false;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'nonce': plan.nonce,
    'workflowRevision': plan.workflowRevision,
    'repository': deploymentRepository,
    'accountId': CloudConfig.accountId,
    'repositoryId': repositoryId,
    'userId': userId,
    'stage': stage,
    'host': host,
    'headSha': headSha,
    'runId': runId,
    'runStatus': runStatus,
    'conclusion': conclusion,
    'workerAttempt': workerAttempt,
    'workflowAttempt': workflowAttempt,
    'dispatchAttempt': dispatchAttempt,
    'entryClosed': entryClosed,
    'cleaned': cleaned,
    'workerClearAttempt': workerClearAttempt,
    'phoneHealthReachable': phoneHealthReachable,
  };
  factory DeploymentRecord.fromJson(Map<String, dynamic> value) {
    if (value['version'] != 1 ||
        value['repository'] != deploymentRepository ||
        value['accountId'] != CloudConfig.accountId ||
        value['nonce'] is! String ||
        (value['workflowRevision'] != null &&
            value['workflowRevision'] is! int) ||
        value['repositoryId'] is! int ||
        value['repositoryId'] <= 0 ||
        value['userId'] is! int ||
        value['userId'] <= 0) {
      throw const ClientFailure(ClientIssue.storage);
    }
    final record = DeploymentRecord(
      plan: DeploymentPlan(
        value['nonce'],
        workflowRevision: value['workflowRevision'] ?? 1,
      ),
      repositoryId: value['repositoryId'],
      userId: value['userId'],
    );
    for (final flag in [
      'workerAttempt',
      'workflowAttempt',
      'dispatchAttempt',
      'entryClosed',
      'cleaned',
      'workerClearAttempt',
    ]) {
      if (value[flag] is! bool) throw const ClientFailure(ClientIssue.storage);
    }
    if ((value['phoneHealthReachable'] != null &&
            value['phoneHealthReachable'] is! bool) ||
        value['stage'] is! String ||
        (value['host'] != null &&
            (value['host'] is! String ||
                !record.plan.validHost(value['host']))) ||
        (value['headSha'] != null &&
            (value['headSha'] is! String ||
                !RegExp(r'^[a-f0-9]{40}$').hasMatch(value['headSha']))) ||
        (value['runId'] != null &&
            (value['runId'] is! int || value['runId'] <= 0)) ||
        value['runStatus'] is! String ||
        (value['conclusion'] != null && value['conclusion'] is! String)) {
      throw const ClientFailure(ClientIssue.storage);
    }
    record.stage = value['stage'];
    record.host = value['host'];
    record.headSha = value['headSha'];
    record.runId = value['runId'];
    record.runStatus = value['runStatus'];
    record.conclusion = value['conclusion'];
    record.workerAttempt = value['workerAttempt'];
    record.workflowAttempt = value['workflowAttempt'];
    record.dispatchAttempt = value['dispatchAttempt'];
    record.entryClosed = value['entryClosed'];
    record.cleaned = value['cleaned'];
    record.workerClearAttempt = value['workerClearAttempt'];
    record.phoneHealthReachable = value['phoneHealthReachable'];
    return record;
  }
}

class DeploymentCredentials {
  const DeploymentCredentials({
    required this.githubToken,
    required this.cloudflareToken,
    required this.repositoryId,
    required this.userId,
  });
  final String githubToken, cloudflareToken;
  final int repositoryId, userId;
}
