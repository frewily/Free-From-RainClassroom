import 'dart:convert';

import 'package:rainclient/client_support.dart';
import 'package:rainclient/deployment/deployment_api.dart';
import 'package:rainclient/deployment/deployment_controller.dart';
import 'package:rainclient/deployment/deployment_model.dart';

class MemoryRecordStore implements RecordStore {
  Map<String, dynamic>? value;
  bool failWrite = false, failDelete = false;
  final writes = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>?> read() async =>
      value == null ? null : jsonDecode(jsonEncode(value!));
  @override
  Future<void> write(Map<String, dynamic> next) async {
    if (failWrite) throw const ClientFailure(ClientIssue.storage);
    value = jsonDecode(jsonEncode(next));
    writes.add(value!);
  }

  @override
  Future<void> delete() async {
    if (failDelete) throw const ClientFailure(ClientIssue.storage);
    value = null;
  }
}

class WireCall {
  WireCall(this.method, this.uri, this.token, this.body, this.contentType);
  final String method;
  final Uri uri;
  final String? token, body;
  final String contentType;
}

class SyntheticDeploymentWire extends Wire {
  late DeploymentRecord Function() current;
  final calls = <WireCall>[];
  bool worker = false, entry = false, workflow = false, run = false;
  String? marker, workflowSourceText;
  bool loseWorkerReply = false,
      loseWorkflowReply = false,
      loseDispatchReply = false;
  bool denyDispatch = false,
      badWorker = false,
      wrongRun = false,
      foreignWorkflow = false,
      foreignBinding = false;
  bool healthReady = true;
  final statuses = <String>[];
  String lastStatus = 'completed';
  String conclusion = 'success';
  int dispatches = 0, workerUploads = 0, fileCreates = 0;
  static const head = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  static const blob = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  WireReply cf(Object result) =>
      WireReply(200, jsonEncode({'success': true, 'result': result}));
  WireReply gh(Object result, [int status = 200]) =>
      WireReply(status, jsonEncode(result));
  WireReply missing() =>
      const WireReply(404, '{"success":false,"message":"Not found"}');

  @override
  Future<WireReply> send(
    String method,
    Uri uri, {
    String? token,
    String? body,
    String contentType = 'application/json',
  }) async {
    calls.add(WireCall(method, uri, token, body, contentType));
    final p = current().plan, path = uri.path;
    if (uri.host.endsWith('.workers.dev')) {
      if (token != null) {
        throw StateError('Synthetic check: credential sent to health endpoint');
      }
      return healthReady
          ? gh({
              'ok': true,
              'kind': 'rain-client-synthetic-v1',
              'instance': p.nonce,
            })
          : missing();
    }
    if (uri.host == 'api.cloudflare.com') {
      if (path == '${p.cfBase}/workers/subdomain') {
        return cf({'subdomain': 'synthetic-domain'});
      }
      if (path == '${p.scriptPath}/settings') {
        return worker
            ? cf({
                'bindings': marker == null
                    ? []
                    : [
                        {
                          'name': 'INSTANCE',
                          'type': 'plain_text',
                          'text': foreignBinding ? 'other-instance' : marker,
                        },
                      ],
              })
            : missing();
      }
      if (path == '${p.scriptPath}/subdomain') {
        if (method == 'POST') entry = jsonDecode(body!)['enabled'];
        return cf({'enabled': entry, 'previews_enabled': false});
      }
      if (path == p.scriptPath && method == 'PUT') {
        workerUploads++;
        if (badWorker) {
          return const WireReply(
            400,
            '{"success":false,"errors":[{"code":10021}]}',
          );
        }
        worker = true;
        marker = body!.contains(closedWorkerSource) ? null : p.nonce;
        if (loseWorkerReply) {
          loseWorkerReply = false;
          throw const ClientFailure(ClientIssue.network);
        }
        return cf({'id': p.worker});
      }
    }
    if (uri.host == 'api.github.com') {
      if (path == p.ghBase) {
        return gh({
          'id': 101,
          'full_name': deploymentRepository,
          'default_branch': 'main',
          'archived': false,
          'disabled': false,
        });
      }
      if (path == '${p.ghBase}/actions/permissions') {
        return gh({'enabled': true});
      }
      if (path == '${p.ghBase}/commits/main') return gh({'sha': head});
      if (path == '${p.ghBase}/contents/${p.workflow}') {
        if (method == 'PUT') {
          fileCreates++;
          workflow = true;
          workflowSourceText = utf8.decode(
            base64.decode(jsonDecode(body!)['content']),
          );
          if (loseWorkflowReply) {
            loseWorkflowReply = false;
            throw const ClientFailure(ClientIssue.network);
          }
          return gh({
            'content': {'sha': blob},
            'commit': {'sha': head},
          }, 201);
        }
        if (method == 'DELETE') {
          workflow = false;
          return gh({
            'commit': {'sha': head},
          });
        }
        return workflow
            ? gh({
                'encoding': 'base64',
                'sha': blob,
                'content': base64.encode(
                  utf8.encode(
                    foreignWorkflow ? 'external change' : workflowSourceText!,
                  ),
                ),
              })
            : missing();
      }
      if (path == '${p.ghBase}/actions/workflows/${p.filename}/dispatches') {
        dispatches++;
        if (denyDispatch) return const WireReply(403, '{"message":"denied"}');
        run = true;
        if (loseDispatchReply) {
          loseDispatchReply = false;
          throw const ClientFailure(ClientIssue.network);
        }
        return gh({'workflow_run_id': 321});
      }
      if (path == '${p.ghBase}/actions/workflows/${p.filename}/runs') {
        return gh({
          'workflow_runs': run
              ? [
                  {'id': 321, 'display_title': p.title, 'head_sha': head},
                ]
              : [],
        });
      }
      if (path == '${p.ghBase}/actions/runs/321') {
        if (statuses.isNotEmpty) lastStatus = statuses.removeAt(0);
        return gh({
          'id': 321,
          'head_sha': wrongRun
              ? 'cccccccccccccccccccccccccccccccccccccccc'
              : head,
          'path': p.workflow,
          'event': 'workflow_dispatch',
          'display_title': p.title,
          'status': lastStatus,
          'conclusion': lastStatus == 'completed' ? conclusion : null,
        });
      }
    }
    throw StateError('Unexpected synthetic endpoint: $method $path');
  }
}

class DeploymentHarness {
  DeploymentHarness({
    MemoryRecordStore? storage,
    SyntheticDeploymentWire? transport,
  }) {
    store = storage ?? MemoryRecordStore();
    wire = transport ?? SyntheticDeploymentWire();
    controller = DeploymentController(
      credentials: () async => const DeploymentCredentials(
        githubToken: 'synthetic_github_token',
        cloudflareToken: 'synthetic_cloudflare_token',
        repositoryId: 101,
        userId: 1,
      ),
      store: store,
      api: DeploymentApi(wire: wire),
      now: () => now,
      observationLimit: const Duration(seconds: 15),
      wait: (duration) async {
        now = now.add(duration);
      },
    );
    wire.current = () => controller.record!;
  }
  DateTime now = DateTime.utc(2026, 10, 30);
  late final MemoryRecordStore store;
  late final SyntheticDeploymentWire wire;
  late final DeploymentController controller;
}
