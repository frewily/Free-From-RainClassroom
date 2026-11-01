import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/deployment/deployment_api.dart';
import 'package:rainclient/deployment/deployment_model.dart';

import 'deployment_fakes.dart';

void main() {
  late DeploymentHarness h;
  setUp(() => h = DeploymentHarness());
  tearDown(() => h.controller.dispose());

  test('legacy plans retain the exact deployed workflow for safe cleanup', () {
    final old = DeploymentRecord(
      plan: DeploymentPlan('141eb6bd4e5da235'),
      repositoryId: 1,
      userId: 2,
    ).toJson()..remove('workflowRevision');
    final restored = DeploymentRecord.fromJson(old);
    expect(restored.plan.workflowRevision, 1);
    final bytes = utf8.encode(
      restored.plan.workflowSource(
        '${restored.plan.worker}.2994508531.workers.dev',
      ),
    );
    // Git blob SHA independently read from the first real deployed file.
    expect(
      sha1.convert([
        ...utf8.encode('blob ${bytes.length}\u0000'),
        ...bytes,
      ]).toString(),
      '9cd82b75ac203d3e46996f9ad134f4b8592eed9a',
    );
  });

  test(
    'new plans preserve their request revision and reject unknown revisions',
    () {
      final json = DeploymentRecord(
        plan: DeploymentPlan('141eb6bd4e5da235'),
        repositoryId: 1,
        userId: 2,
      ).toJson();
      expect(DeploymentRecord.fromJson(json).plan.workflowRevision, 2);
      expect(
        () => DeploymentRecord.fromJson({...json, 'workflowRevision': 3}),
        throwsA(isA<Exception>()),
      );
    },
  );

  test(
    'generated cloud probe reaches a service rejecting Python default agents',
    () async {
      final plan = DeploymentPlan('141eb6bd4e5da235');
      final workflow = plan.workflowSource(
        '${plan.worker}.2994508531.workers.dev',
      );
      final program = workflow
          .split("          python3 - <<'PY'\n")
          .last
          .split('\n')
          .takeWhile((line) => line.trim() != 'PY')
          .map(
            (line) => line.startsWith('          ') ? line.substring(10) : line,
          )
          .join('\n');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final agents = <String?>[];
      server.listen((request) async {
        final agent = request.headers.value(HttpHeaders.userAgentHeader);
        agents.add(agent);
        if (agent != 'RainClient-Deployment-Probe/1.0') {
          request.response.statusCode = HttpStatus.forbidden;
        } else {
          request.response.write(
            jsonEncode({
              'ok': true,
              'kind': 'rain-client-synthetic-v1',
              'instance': plan.nonce,
            }),
          );
        }
        await request.response.close();
      });
      try {
        final result = await Process.run(
          'python3',
          ['-c', program],
          environment: {
            'HEALTH_URL': 'http://127.0.0.1:${server.port}/health',
            'EXPECTED_INSTANCE': plan.nonce,
            'NO_PROXY': '127.0.0.1',
            'no_proxy': '127.0.0.1',
          },
        ).timeout(const Duration(seconds: 10));
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(agents, ['RainClient-Deployment-Probe/1.0']);
        expect(
          result.stdout,
          contains('Rain client synthetic environment verified'),
        );
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'cloud task validates deployment when handset health route is unavailable',
    () async {
      await h.controller.prepare();
      h.wire.healthReady = false;
      await h.controller.deploy();
      expect(h.wire.dispatches, 1);
      expect(h.controller.successful, isTrue);
      expect(h.controller.record!.phoneHealthReachable, isFalse);
    },
  );
  test(
    'handset route failure never hides a failing cloud verification',
    () async {
      await h.controller.prepare();
      h.wire.healthReady = false;
      h.wire.conclusion = 'failure';
      await h.controller.deploy();
      expect(h.wire.dispatches, 1);
      expect(h.controller.successful, isFalse);
      expect(h.controller.record!.phoneHealthReachable, isFalse);
    },
  );
  test(
    'pre-existing plans without handset route metadata still restore',
    () async {
      await h.controller.prepare();
      final old = h.controller.record!.toJson()..remove('phoneHealthReachable');
      expect(DeploymentRecord.fromJson(old).phoneHealthReachable, isNull);
    },
  );

  test(
    'cleanup rechecks and closes an entry reopened since the last check',
    () async {
      await h.controller.prepare();
      await h.controller.deploy();
      expect(h.controller.record!.entryClosed, isTrue);
      h.wire.entry = true;
      await h.controller.cleanup();
      expect(h.wire.entry, isFalse);
      expect(h.controller.record!.cleaned, isTrue);
    },
  );

  test(
    'preparation is read-only and persists a concrete unique resource list',
    () async {
      await h.controller.prepare();
      expect(h.controller.record!.stage, 'prepared');
      expect(h.wire.calls.every((c) => c.method == 'GET'), isTrue);
      expect(h.wire.worker, isFalse);
      expect(h.wire.dispatches, 0);
      expect(h.store.value!['nonce'], h.controller.record!.plan.nonce);
    },
  );
  test('deployment passes only after real-shaped completed success and entry readback', () async {
    await h.controller.prepare();
    await h.controller.deploy();
    expect(h.controller.successful, isTrue);
    expect(h.controller.record!.runId, 321);
    expect(h.wire.worker, isTrue);
    expect(h.wire.workflow, isTrue);
    expect(h.wire.entry, isFalse);
    expect(h.wire.dispatches, 1);
    expect(
      h.wire.calls
          .where((c) => c.uri.host.endsWith('.workers.dev'))
          .every((c) => c.token == null),
      isTrue,
    );
    expect(
      h.wire.calls.any(
        (c) =>
            c.uri.path.contains('/secrets') ||
            c.uri.path.contains('/d1/') ||
            c.uri.path.contains('/storage/'),
      ),
      isFalse,
    );
  });
  test(
    'queueing is displayed without confusing dispatch acceptance with success',
    () async {
      await h.controller.prepare();
      h.wire.lastStatus = 'queued';
      await h.controller.deploy();
      expect(h.controller.successful, isFalse);
      expect(h.controller.record!.stage, 'waiting_for_run');
      expect(h.wire.dispatches, 1);
      h.wire.lastStatus = 'completed';
      await h.controller.deploy();
      expect(h.controller.successful, isTrue);
      expect(h.wire.dispatches, 1);
    },
  );
  test('unknown upload and workflow-create responses are reconciled without repeat writes', () async {
    await h.controller.prepare();
    h.wire.loseWorkerReply = true;
    h.wire.loseWorkflowReply = true;
    await h.controller.deploy();
    expect(h.controller.successful, isTrue);
    expect(h.wire.workerUploads, 1);
    expect(h.wire.fileCreates, 1);
  });
  test('a lost dispatch response is found by its unique workflow and never replayed', () async {
    await h.controller.prepare();
    h.wire.loseDispatchReply = true;
    await h.controller.deploy();
    await h.controller.deploy();
    expect(h.controller.successful, isTrue);
    expect(h.wire.dispatches, 1);
  });
  test(
    'restart recovers the same pending run and sends no extra dispatch',
    () async {
      await h.controller.prepare();
      h.wire.lastStatus = 'queued';
      await h.controller.deploy();
      h.controller.dispose();
      h = DeploymentHarness(storage: h.store, transport: h.wire);
      await h.controller.restore();
      h.wire.lastStatus = 'completed';
      await h.controller.deploy();
      expect(h.controller.successful, isTrue);
      expect(h.wire.dispatches, 1);
    },
  );
  test(
    'checkpoint failure prevents any cloud or repository mutation',
    () async {
      h.store.failWrite = true;
      await h.controller.prepare();
      expect(h.wire.calls, isEmpty);
      expect(h.wire.dispatches, 0);
      expect(h.controller.message, contains('保存'));
    },
  );
  test(
    'known Worker compile rejection preserves status and numeric provider code',
    () async {
      await h.controller.prepare();
      h.wire.badWorker = true;
      await h.controller.deploy();
      expect(h.controller.message, contains('400'));
      expect(h.controller.message, contains('10021'));
      expect(h.wire.fileCreates, 0);
      expect(h.wire.dispatches, 0);
    },
  );
  test('foreign binding prevents resuming or overwriting the worker', () async {
    await h.controller.prepare();
    h.wire.worker = true;
    h.wire.marker = 'external';
    await h.controller.deploy();
    expect(h.wire.workerUploads, 0);
    expect(h.wire.dispatches, 0);
  });
  test('a rejected dispatch remains rejected and is never silently submitted again', () async {
    await h.controller.prepare();
    h.wire.denyDispatch = true;
    await h.controller.deploy();
    expect(h.controller.message, contains('403'));
    expect(h.controller.record!.runStatus, 'rejected');
    await h.controller.deploy();
    expect(h.wire.dispatches, 1);
  });
  test('wrong run identity is not claimed as successful', () async {
    await h.controller.prepare();
    h.wire.wrongRun = true;
    await h.controller.deploy();
    expect(h.controller.successful, isFalse);
  });
  test(
    'failed task is distinct from successful deployment verification',
    () async {
      await h.controller.prepare();
      h.wire.conclusion = 'failure';
      await h.controller.deploy();
      expect(h.controller.successful, isFalse);
      expect(h.controller.record!.conclusion, 'failure');
      expect(h.wire.entry, isFalse);
    },
  );
  test(
    'cleanup deletes only matching workflow and retains a closed empty Worker',
    () async {
      await h.controller.prepare();
      await h.controller.deploy();
      await h.controller.cleanup();
      expect(h.controller.record!.cleaned, isTrue);
      expect(h.wire.workflow, isFalse);
      expect(h.wire.worker, isTrue);
      expect(h.wire.marker, isNull);
      expect(h.wire.entry, isFalse);
      expect(
        h.wire.calls
            .where((c) => c.method == 'DELETE')
            .every((c) => c.uri.host == 'api.github.com'),
        isTrue,
      );
    },
  );
  test('cleanup preserves an externally modified workflow', () async {
    await h.controller.prepare();
    await h.controller.deploy();
    h.wire.foreignWorkflow = true;
    await h.controller.cleanup();
    expect(h.wire.workflow, isTrue);
    expect(h.controller.record!.cleaned, isFalse);
    expect(h.wire.calls.any((c) => c.method == 'DELETE'), isFalse);
  });
  test(
    'cleanup does not adopt an externally cleared unmarked Worker',
    () async {
      await h.controller.prepare();
      await h.controller.deploy();
      h.wire.marker = null;
      final uploads = h.wire.workerUploads;
      await h.controller.cleanup();
      expect(h.wire.workerUploads, uploads);
      expect(h.controller.record!.cleaned, isFalse);
    },
  );
  test('endpoint boundary refuses production resources, other repos and broad deletes', () async {
    await h.controller.prepare();
    final r = h.controller.record!, p = r.plan;
    expect(DeploymentApi.allows(r, 'PUT', p.scriptPath), isTrue);
    expect(DeploymentApi.allows(r, 'DELETE', p.scriptPath), isFalse);
    expect(
      DeploymentApi.allows(r, 'PUT', '${p.cfBase}/workers/scripts/production'),
      isFalse,
    );
    expect(
      DeploymentApi.allows(
        r,
        'PUT',
        '/repos/frewily/Fuck-Yangtze-RainClassroom/contents/file',
        github: true,
      ),
      isFalse,
    );
    expect(
      DeploymentApi.allows(
        r,
        'POST',
        '${p.ghBase}/actions/workflows/other.yml/dispatches',
        github: true,
      ),
      isFalse,
    );
  });
  test(
    'workflow contains no checkout, credentials or automatic trigger',
    () async {
      await h.controller.prepare();
      final r = h.controller.record!;
      final source = r.plan.workflowSource(r.host!);
      expect(source, contains('on: workflow_dispatch'));
      expect(source, contains('permissions: {}'));
      expect(source.contains('actions/checkout'), isFalse);
      expect(source.contains('secrets.'), isFalse);
      expect(source.contains('schedule:'), isFalse);
      expect(source.contains('on: push'), isFalse);
      final restored = DeploymentRecord.fromJson(
        jsonDecode(jsonEncode(r.toJson())),
      );
      expect(restored.plan.nonce, r.plan.nonce);
      expect(restored.plan.validHost('example.com'), isFalse);
    },
  );
}
