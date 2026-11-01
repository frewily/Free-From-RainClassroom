import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../client_support.dart';
import 'deployment_api.dart';
import 'deployment_model.dart';

class DeploymentController extends ChangeNotifier {
  DeploymentController({
    required this.credentials,
    required this.store,
    DeploymentApi? api,
    DateTime Function()? now,
    Future<void> Function(Duration)? wait,
    this.observationLimit = const Duration(minutes: 3),
    this.ioTimeout = const Duration(seconds: 8),
  }) : api = api ?? DeploymentApi(),
       now = now ?? DateTime.now,
       wait = wait ?? Future<void>.delayed;
  final Future<DeploymentCredentials> Function() credentials;
  final RecordStore store;
  final DeploymentApi api;
  final DateTime Function() now;
  final Future<void> Function(Duration) wait;
  final Duration observationLimit, ioTimeout;
  final _storage = SerialWork();
  DeploymentRecord? record;
  bool busy = false;
  bool _disposed = false;
  int _generation = 0;
  String message = '连接 GitHub 和 Cloudflare 后，检查并生成测试部署清单。';
  final List<String> events = [];
  bool get successful =>
      record?.runStatus == 'completed' &&
      record?.conclusion == 'success' &&
      record?.entryClosed == true;
  void _show(String text) {
    if (_disposed) return;
    message = text;
    if (events.isEmpty || events.last != text) events.add(text);
    if (events.length > 30) events.removeAt(0);
    notifyListeners();
  }

  void _check(int op) {
    if (_disposed || op != _generation) {
      throw const ClientFailure(ClientIssue.cancelled);
    }
  }

  Future<T> _local<T>(Future<T> future) async {
    try {
      return await future.timeout(ioTimeout);
    } on Object {
      throw const ClientFailure(ClientIssue.storage);
    }
  }

  Future<void> _save(String stage, int op) async {
    _check(op);
    record!.stage = stage;
    final snapshot = record!.toJson();
    await _local(
      _storage.run(() async {
        _check(op);
        await store.write(snapshot);
      }),
    );
    _check(op);
  }

  Future<WireReply> _request(
    DeploymentCredentials c,
    int op,
    String method,
    String path, {
    bool github = false,
    Map<String, dynamic>? json,
    String? source,
  }) async {
    _check(op);
    final r = await api.request(
      record!,
      c,
      method,
      path,
      github: github,
      json: json,
      source: source,
    );
    _check(op);
    return r;
  }

  ClientFailure _rejected(WireReply r) {
    int? code;
    try {
      final errors = r.json()['errors'];
      if (errors is List &&
          errors.isNotEmpty &&
          errors.first is Map &&
          errors.first['code'] is int) {
        code = errors.first['code'];
      }
    } on Object {
      /* Only structured numeric diagnostics are retained. */
    }
    return ClientFailure(
      r.status == 401 ? ClientIssue.authorization : ClientIssue.response,
      httpStatus: r.status,
      providerCode: code,
    );
  }

  Map<String, dynamic> _github(WireReply r, {int status = 200}) {
    if (r.status != status) throw _rejected(r);
    return r.json();
  }

  Map<String, dynamic> _cloud(WireReply r) {
    final body = r.json();
    if (![200, 201].contains(r.status) ||
        body['success'] != true ||
        body['result'] is! Map<String, dynamic>) {
      throw _rejected(r);
    }
    return body['result'] as Map<String, dynamic>;
  }

  Future<void> _work(Future<void> Function(int) action) async {
    if (busy || _disposed) return;
    busy = true;
    final op = ++_generation;
    notifyListeners();
    try {
      await action(op);
    } on Object catch (error) {
      if (!_disposed && op == _generation) {
        final safe = error is ClientFailure
            ? error
            : const ClientFailure(ClientIssue.authorization);
        final detail = safe.httpStatus == null
            ? ''
            : '（HTTP ${safe.httpStatus}${safe.providerCode == null ? '' : ' / ${safe.providerCode}'}）';
        _show(switch (safe.issue) {
          ClientIssue.authorization =>
            '请先重新确认 GitHub、所选原测试仓库和 Cloudflare 连接。$detail',
          ClientIssue.storage => '本机进度保存尚未确认，已停止后续操作；请重试检查。',
          ClientIssue.conflict => '资源或文件状态与本次计划不一致，已停止操作，保留现场。$detail',
          ClientIssue.cancelled => '本次操作已停止，重开后可继续检查。',
          _ => '平台或网络暂未完成当前步骤$detail。可继续检查，不会重复触发同一任务。',
        });
      }
    } finally {
      if (!_disposed && op == _generation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> restore() => _work((op) async {
    final raw = await _local(_storage.run(store.read));
    _check(op);
    if (raw != null) {
      record = DeploymentRecord.fromJson(raw);
      _show(record!.cleaned ? '上次测试已清理，可以生成新清单。' : '已恢复本机测试进度，可继续检查或清理本次资源。');
    }
  });

  Future<DeploymentCredentials> _context(int op) async {
    final c = await credentials();
    _check(op);
    if (record != null &&
        (c.repositoryId != record!.repositoryId ||
            c.userId != record!.userId)) {
      throw const ClientFailure(ClientIssue.authorization);
    }
    return c;
  }

  Future<void> prepare() => _work((op) async {
    if (record != null && !record!.cleaned) {
      throw const ClientFailure(ClientIssue.conflict);
    }
    _show('正在检查两个账号和原空测试仓库。');
    final c = await credentials();
    _check(op);
    record = DeploymentRecord(
      plan: DeploymentPlan.create(),
      repositoryId: c.repositoryId,
      userId: c.userId,
    );
    await _save('preflight', op);
    await _preflight(c, op);
    await _save('prepared', op);
    _show('检查通过。请核对下方清单，再确认部署并运行一次空任务。');
  });
  Future<void> _preflight(DeploymentCredentials c, int op) async {
    final p = record!.plan;
    final repo = _github(await _request(c, op, 'GET', p.ghBase, github: true));
    if (repo['id'] != record!.repositoryId ||
        repo['full_name'] != deploymentRepository ||
        repo['default_branch'] != 'main' ||
        repo['archived'] != false ||
        repo['disabled'] == true) {
      throw const ClientFailure(ClientIssue.authorization);
    }
    final permissions = _github(
      await _request(
        c,
        op,
        'GET',
        '${p.ghBase}/actions/permissions',
        github: true,
      ),
    );
    if (permissions['enabled'] != true) {
      throw const ClientFailure(ClientIssue.authorization);
    }
    final domain = _cloud(
      await _request(c, op, 'GET', '${p.cfBase}/workers/subdomain'),
    )['subdomain'];
    if (domain is! String || !RegExp(r'^[a-z0-9-]{1,63}$').hasMatch(domain)) {
      throw const ClientFailure(ClientIssue.response);
    }
    final host = '${p.worker}.$domain.workers.dev';
    if (record!.host != null && record!.host != host) {
      throw const ClientFailure(ClientIssue.conflict);
    }
    record!.host = host;
    final worker = await _request(c, op, 'GET', '${p.scriptPath}/settings');
    if (record!.workerAttempt) {
      if (worker.status != 404 && !_ownsWorker(worker)) {
        throw const ClientFailure(ClientIssue.conflict);
      }
    } else if (worker.status != 404) {
      throw const ClientFailure(ClientIssue.conflict);
    }
    final workflow = await _request(
      c,
      op,
      'GET',
      '${p.ghBase}/contents/${p.workflow}',
      github: true,
    );
    if (record!.workflowAttempt) {
      if (workflow.status != 404) _verifyWorkflow(workflow);
    } else if (workflow.status != 404) {
      throw const ClientFailure(ClientIssue.conflict);
    }
  }

  bool _ownsWorker(WireReply reply) {
    final bindings = _cloud(reply)['bindings'];
    return bindings is List &&
        bindings.length == 1 &&
        bindings.single is Map &&
        bindings.single['name'] == 'INSTANCE' &&
        bindings.single['type'] == 'plain_text' &&
        bindings.single['text'] == record!.plan.nonce;
  }

  String _verifyWorkflow(WireReply reply) {
    final body = _github(reply);
    final content = body['content'], sha = body['sha'];
    if (body['encoding'] != 'base64' ||
        content is! String ||
        sha is! String ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(sha)) {
      throw const ClientFailure(ClientIssue.conflict);
    }
    try {
      if (utf8.decode(base64.decode(content.replaceAll(RegExp(r'\s'), ''))) !=
          record!.plan.workflowSource(record!.host!)) {
        throw const ClientFailure(ClientIssue.conflict);
      }
    } on FormatException {
      throw const ClientFailure(ClientIssue.conflict);
    }
    return sha;
  }

  /// Called only after the in-app review shows this exact persisted resource list.
  Future<void> deploy() => _work((op) async {
    if (record == null || record!.cleaned || record!.host == null) {
      throw const ClientFailure(ClientIssue.conflict);
    }
    final c = await _context(op);
    final p = record!.plan;
    if (record!.dispatchAttempt) {
      await _observe(c, op);
      return;
    }
    await _preflight(c, op);
    _show('正在部署本次合成测试 Worker。');
    if (!record!.workerAttempt) {
      record!.workerAttempt = true;
      await _save('worker_upload_intent', op);
      try {
        _cloud(
          await _request(c, op, 'PUT', p.scriptPath, source: workerSource),
        );
      } on ClientFailure catch (error) {
        if (error.issue != ClientIssue.network) rethrow;
      }
    }
    if (!_ownsWorker(
      await _request(c, op, 'GET', '${p.scriptPath}/settings'),
    )) {
      throw const ClientFailure(ClientIssue.conflict);
    }
    _show('正在准备原空仓库中的单份测试工作流。');
    if (!record!.workflowAttempt) {
      record!.workflowAttempt = true;
      await _save('workflow_create_intent', op);
      try {
        _github(
          await _request(
            c,
            op,
            'PUT',
            '${p.ghBase}/contents/${p.workflow}',
            github: true,
            json: {
              'message': 'Rain client test ${p.nonce}',
              'branch': 'main',
              'content': base64.encode(
                utf8.encode(p.workflowSource(record!.host!)),
              ),
            },
          ),
          status: 201,
        );
      } on ClientFailure catch (error) {
        if (error.issue != ClientIssue.network) rethrow;
      }
    }
    _verifyWorkflow(
      await _request(
        c,
        op,
        'GET',
        '${p.ghBase}/contents/${p.workflow}',
        github: true,
      ),
    );
    await _save('entry_enable_intent', op);
    _cloud(
      await _request(
        c,
        op,
        'POST',
        '${p.scriptPath}/subdomain',
        json: {'enabled': true, 'previews_enabled': false},
      ),
    );
    record!.entryClosed = false;
    await _save('checking_worker', op);
    _show('正在检查手机直连；完整部署验证由云端空任务执行。');
    var healthy = false;
    try {
      final health = await api
          .health(record!)
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () {
              // No deployment API request is in flight here; cancel only this probe.
              api.cancel();
              throw const ClientFailure(ClientIssue.network);
            },
          );
      _check(op);
      final body = health.json();
      healthy =
          health.status == 200 &&
          body['ok'] == true &&
          body['kind'] == 'rain-client-synthetic-v1' &&
          body['instance'] == p.nonce;
    } on ClientFailure {
      /* A handset route failure is not a verdict on the cloud-to-cloud path. */
    }
    _check(op);
    record!.phoneHealthReachable = healthy;
    await _save('handset_health_checked', op);
    if (!healthy) _show('手机当前网络无法直连测试服务，将由云端空任务严格核验。');
    _verifyWorkflow(
      await _request(
        c,
        op,
        'GET',
        '${p.ghBase}/contents/${p.workflow}',
        github: true,
      ),
    );
    final head = _github(
      await _request(c, op, 'GET', '${p.ghBase}/commits/main', github: true),
    )['sha'];
    if (head is! String || !RegExp(r'^[a-f0-9]{40}$').hasMatch(head)) {
      throw const ClientFailure(ClientIssue.response);
    }
    record!.headSha = head;
    record!.dispatchAttempt = true;
    record!.runStatus = 'result_unknown';
    await _save('dispatch_intent', op);
    _show('正在提交唯一一次空任务。');
    try {
      final reply = await _request(
        c,
        op,
        'POST',
        '${p.ghBase}/actions/workflows/${p.filename}/dispatches',
        github: true,
        json: {'ref': 'main'},
      );
      if (![200, 204].contains(reply.status)) {
        record!.runStatus = 'rejected';
        await _save('dispatch_rejected', op);
        throw _rejected(reply);
      }
      Object? id;
      if (reply.status == 200) {
        try {
          id = reply.json()['workflow_run_id'];
        } on ClientFailure {
          /* Reconcile accepted replies by lookup. */
        }
      }
      if (id is int && id > 0) record!.runId = id;
      record!.runStatus = 'accepted';
    } on ClientFailure catch (error) {
      _check(op);
      if (error.issue != ClientIssue.network) rethrow;
    }
    await _save('observing', op);
    await _observe(c, op);
  });

  Future<void> _observe(DeploymentCredentials c, int op) async {
    if (record!.runStatus == 'rejected') {
      throw const ClientFailure(ClientIssue.conflict);
    }
    final p = record!.plan;
    _show('正在查看空任务的真实运行状态，排队期间请稍候。');
    final deadline = now().add(observationLimit);
    while (now().isBefore(deadline)) {
      if (record!.runId == null) {
        final runs = _github(
          await _request(
            c,
            op,
            'GET',
            '${p.ghBase}/actions/workflows/${p.filename}/runs?event=workflow_dispatch&per_page=10',
            github: true,
          ),
        )['workflow_runs'];
        if (runs is! List) throw const ClientFailure(ClientIssue.response);
        final matches = runs
            .where(
              (r) =>
                  r is Map &&
                  r['display_title'] == p.title &&
                  r['head_sha'] == record!.headSha,
            )
            .toList();
        if (matches.length > 1) throw const ClientFailure(ClientIssue.conflict);
        if (matches.length == 1) {
          final id = matches.single['id'];
          if (id is! int || id <= 0) {
            throw const ClientFailure(ClientIssue.response);
          }
          record!.runId = id;
          await _save('observing', op);
        }
      }
      if (record!.runId != null) {
        final run = _github(
          await _request(
            c,
            op,
            'GET',
            '${p.ghBase}/actions/runs/${record!.runId}',
            github: true,
          ),
        );
        if (run['head_sha'] != record!.headSha ||
            run['path'] != p.workflow ||
            run['event'] != 'workflow_dispatch' ||
            run['display_title'] != p.title ||
            ![
              'queued',
              'in_progress',
              'completed',
              'waiting',
              'pending',
              'requested',
            ].contains(run['status']) ||
            ![
              null,
              'success',
              'failure',
              'cancelled',
              'skipped',
              'timed_out',
              'action_required',
              'neutral',
              'stale',
              'startup_failure',
            ].contains(run['conclusion'])) {
          throw const ClientFailure(ClientIssue.conflict);
        }
        record!.runStatus = run['status'];
        record!.conclusion = run['conclusion'] is String
            ? run['conclusion']
            : null;
        await _save('observing', op);
        _show(
          run['status'] == 'in_progress'
              ? '空任务正在执行。'
              : '空任务状态：${run['status']}。',
        );
        if (run['status'] == 'completed') {
          await _closeEntry(c, op);
          await _save('finished', op);
          _show(
            successful
                ? '验证通过：测试环境已部署，空任务实际成功，测试公网入口已关闭。'
                : '空任务已结束，结果为 ${record!.conclusion ?? '未知'}；测试入口已关闭，可查看任务或清理。',
          );
          return;
        }
      }
      await wait(const Duration(seconds: 5));
      _check(op);
    }
    await _save('waiting_for_run', op);
    _show('任务仍在排队或运行，稍后可继续检查；不会再次提交同一任务。测试入口会在确认任务结束或清理时关闭。');
  }

  Future<void> _closeEntry(DeploymentCredentials c, int op) async {
    if (!_ownsWorker(
      await _request(c, op, 'GET', '${record!.plan.scriptPath}/settings'),
    )) {
      throw const ClientFailure(ClientIssue.conflict);
    }
    final actual = _cloud(
      await _request(c, op, 'GET', '${record!.plan.scriptPath}/subdomain'),
    );
    if (actual['enabled'] == false && actual['previews_enabled'] == false) {
      record!.entryClosed = true;
      await _save('entry_closed', op);
      return;
    }
    await _save('closing_entry', op);
    _cloud(
      await _request(
        c,
        op,
        'POST',
        '${record!.plan.scriptPath}/subdomain',
        json: {'enabled': false, 'previews_enabled': false},
      ),
    );
    final check = _cloud(
      await _request(c, op, 'GET', '${record!.plan.scriptPath}/subdomain'),
    );
    if (check['enabled'] != false || check['previews_enabled'] != false) {
      throw const ClientFailure(ClientIssue.response);
    }
    record!.entryClosed = true;
    await _save('entry_closed', op);
  }

  Future<void> cleanup() => _work((op) async {
    if (record == null || record!.cleaned) return;
    final c = await _context(op);
    final p = record!.plan;
    _show('正在关闭本次测试入口并检查清理范围。');
    if (record!.workerAttempt) {
      final worker = await _request(c, op, 'GET', '${p.scriptPath}/settings');
      if (worker.status != 404) {
        final bindings = _cloud(worker)['bindings'];
        if (!(record!.workerClearAttempt &&
                bindings is List &&
                bindings.isEmpty) &&
            !_ownsWorker(worker)) {
          throw const ClientFailure(ClientIssue.conflict);
        }
        if (bindings is List && bindings.isEmpty) {
          _cloud(
            await _request(
              c,
              op,
              'POST',
              '${p.scriptPath}/subdomain',
              json: {'enabled': false, 'previews_enabled': false},
            ),
          );
          final closed = _cloud(
            await _request(c, op, 'GET', '${p.scriptPath}/subdomain'),
          );
          if (closed['enabled'] != false ||
              closed['previews_enabled'] != false) {
            throw const ClientFailure(ClientIssue.response);
          }
          record!.entryClosed = true;
        } else {
          await _closeEntry(c, op);
        }
        record!.workerClearAttempt = true;
        await _save('cleanup_worker', op);
        _cloud(
          await _request(
            c,
            op,
            'PUT',
            p.scriptPath,
            source: closedWorkerSource,
          ),
        );
        final checked = _cloud(
          await _request(c, op, 'GET', '${p.scriptPath}/settings'),
        )['bindings'];
        if (checked is! List || checked.isNotEmpty) {
          throw const ClientFailure(ClientIssue.response);
        }
      }
      record!.entryClosed = true;
    }
    if (record!.workflowAttempt) {
      final file = await _request(
        c,
        op,
        'GET',
        '${p.ghBase}/contents/${p.workflow}',
        github: true,
      );
      if (file.status != 404) {
        final sha = _verifyWorkflow(file);
        await _save('cleanup_workflow', op);
        try {
          _github(
            await _request(
              c,
              op,
              'DELETE',
              '${p.ghBase}/contents/${p.workflow}',
              github: true,
              json: {
                'message': 'Rain client cleanup ${p.nonce}',
                'sha': sha,
                'branch': 'main',
              },
            ),
          );
        } on Object {
          _check(op);
        }
        if ((await _request(
              c,
              op,
              'GET',
              '${p.ghBase}/contents/${p.workflow}',
              github: true,
            )).status !=
            404) {
          throw const ClientFailure(ClientIssue.conflict);
        }
      }
    }
    record!.cleaned = true;
    await _save('cleaned', op);
    _show('本次测试已按实际状态清理：公网入口关闭、测试文件移除；存在的空 Worker 及正常 Git／运行历史保留。');
  });
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    api.cancel();
    super.dispose();
  }
}
