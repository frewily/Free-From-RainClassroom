import 'dart:convert';

import '../client_support.dart';
import '../cloudflare/cloudflare_auth.dart';
import 'deployment_model.dart';

class DeploymentApi {
  DeploymentApi({Wire? wire}) : wire = wire ?? HttpsWire(_allowsHost);
  final Wire wire;
  static bool _allowsHost(String method, Uri uri, bool token) {
    if (uri.host == 'api.cloudflare.com' && token) {
      return uri.path.startsWith(
        '/client/v4/accounts/${CloudConfig.accountId}/',
      );
    }
    if (uri.host == 'api.github.com' && token) {
      return uri.path.startsWith('/repos/$deploymentRepository');
    }
    return method == 'GET' &&
        !token &&
        uri.host.endsWith('.workers.dev') &&
        uri.path == '/health' &&
        !uri.hasQuery;
  }

  static bool allows(
    DeploymentRecord record,
    String method,
    String path, {
    bool github = false,
  }) {
    final p = record.plan;
    if (github) {
      if (method == 'GET' &&
          [
            p.ghBase,
            '${p.ghBase}/actions/permissions',
            '${p.ghBase}/commits/main',
            '${p.ghBase}/contents/${p.workflow}',
            '${p.ghBase}/actions/workflows/${p.filename}/runs?event=workflow_dispatch&per_page=10',
            if (record.runId != null)
              '${p.ghBase}/actions/runs/${record.runId}',
          ].contains(path)) {
        return true;
      }
      return (method == 'PUT' || method == 'DELETE') &&
              path == '${p.ghBase}/contents/${p.workflow}' ||
          method == 'POST' &&
              path == '${p.ghBase}/actions/workflows/${p.filename}/dispatches';
    }
    return method == 'GET' &&
            [
              '${p.cfBase}/workers/subdomain',
              '${p.scriptPath}/settings',
              '${p.scriptPath}/subdomain',
            ].contains(path) ||
        method == 'PUT' && path == p.scriptPath ||
        method == 'POST' && path == '${p.scriptPath}/subdomain';
  }

  Future<WireReply> request(
    DeploymentRecord record,
    DeploymentCredentials credentials,
    String method,
    String path, {
    bool github = false,
    Map<String, dynamic>? json,
    String? source,
  }) async {
    if (!allows(record, method, path, github: github)) {
      throw const ClientFailure(ClientIssue.response);
    }
    final base = Uri.parse(
      'https://${github ? 'api.github.com' : 'api.cloudflare.com'}',
    );
    var type = 'application/json';
    String? body = json == null ? null : jsonEncode(json);
    if (source != null) {
      if (github || method != 'PUT' || path != record.plan.scriptPath) {
        throw const ClientFailure(ClientIssue.response);
      }
      final boundary = 'rain-client-${record.plan.nonce}';
      final bindings = source == closedWorkerSource
          ? <Object>[]
          : [
              {
                'name': 'INSTANCE',
                'type': 'plain_text',
                'text': record.plan.nonce,
              },
            ];
      type = 'multipart/form-data; boundary=$boundary';
      body = [
        '--$boundary',
        'Content-Disposition: form-data; name="metadata"',
        'Content-Type: application/json',
        '',
        jsonEncode({
          'main_module': 'worker.mjs',
          'compatibility_date': '2026-10-01',
          'bindings': bindings,
        }),
        '--$boundary',
        'Content-Disposition: form-data; name="worker.mjs"; filename="worker.mjs"',
        'Content-Type: application/javascript+module',
        '',
        source,
        '--$boundary--',
        '',
      ].join('\r\n');
    }
    return wire.send(
      method,
      base.resolve(path),
      token: github ? credentials.githubToken : credentials.cloudflareToken,
      body: body,
      contentType: type,
    );
  }

  Future<WireReply> health(DeploymentRecord record) {
    if (record.host == null || !record.plan.validHost(record.host!)) {
      throw const ClientFailure(ClientIssue.response);
    }
    return wire.send('GET', Uri.https(record.host!, '/health'));
  }

  void cancel() => wire.cancel();
}
