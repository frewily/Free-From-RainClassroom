import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../auth/session_cookie.dart';
import '../client_support.dart';
import 'course_model.dart';

enum CourseResource { identity, joined, archived }

abstract class CourseTransport {
  Future<WireReply> get(
    CourseResource resource,
    String session, {
    String? accountId,
  });
  void cancel() {}
}

/// No arbitrary URL, method, redirect or write request is available to this reader.
class DartCourseTransport extends CourseTransport {
  static const maxBytes = 1024 * 1024;
  final _active = <HttpClient>{};

  static Uri endpoint(CourseResource resource, {String? accountId}) =>
      switch (resource) {
        CourseResource.identity => Uri.parse(
          '$courseOrigin/v2/api/web/userinfo',
        ),
        CourseResource.joined => Uri.parse(
          '$courseOrigin/v2/api/web/courses/list?identity=2',
        ),
        CourseResource.archived => Uri.parse(
          '$courseOrigin/v2/api/web/classroom_archive',
        ).replace(queryParameters: {'user_id': courseIdentifier(accountId)}),
      };

  @override
  Future<WireReply> get(
    CourseResource resource,
    String session, {
    String? accountId,
  }) async {
    if (!isSafeSessionValue(session)) {
      throw const CourseFailure(CourseIssue.login);
    }
    final uri = endpoint(resource, accountId: accountId);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _active.add(client);
    Future<WireReply> request() async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'RainClient-CourseReader/0.4',
      );
      request.headers.set(HttpHeaders.cookieHeader, 'sessionid=$session');
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const CourseFailure(CourseIssue.response, stage: 'size');
        }
        bytes.addAll(chunk);
      }
      return WireReply(response.statusCode, utf8.decode(bytes));
    }

    try {
      return await request().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          client.close(force: true);
          throw TimeoutException('Course read timed out');
        },
      );
    } finally {
      client.close(force: true);
      _active.remove(client);
    }
  }

  @override
  void cancel() {
    for (final client in _active.toList()) {
      client.close(force: true);
    }
    _active.clear();
  }
}

abstract class CourseGateway {
  Future<CourseAccount> identify(String session);
  Future<CourseListing> list(
    String session,
    CourseAccount account, {
    required bool archived,
  });
  void cancel() {}
}

class CourseClient extends CourseGateway {
  CourseClient({CourseTransport? transport})
    : _transport = transport ?? DartCourseTransport();
  final CourseTransport _transport;

  Future<Map<String, dynamic>> _read(
    CourseResource resource,
    String session, {
    String? accountId,
  }) async {
    if (!isSafeSessionValue(session)) {
      throw const CourseFailure(CourseIssue.login);
    }
    try {
      final reply = await _transport.get(
        resource,
        session,
        accountId: accountId,
      );
      if (reply.body.length > DartCourseTransport.maxBytes) {
        throw const CourseFailure(CourseIssue.response, stage: 'size');
      }
      Object? decoded;
      try {
        decoded = jsonDecode(reply.body);
      } on FormatException {
        if (reply.status == 401) throw const CourseFailure(CourseIssue.login);
        throw CourseFailure(
          CourseIssue.response,
          stage: resource.name,
          httpStatus: reply.status,
        );
      }
      if (reply.status == 401 ||
          (decoded is Map &&
              [200, 401].contains(reply.status) &&
              [401000, 401002].contains(decoded['errcode']))) {
        throw const CourseFailure(CourseIssue.login);
      }
      if (reply.status != 200 ||
          decoded is! Map<String, dynamic> ||
          decoded['errcode'] is! int ||
          decoded['errcode'] != 0) {
        throw CourseFailure(
          CourseIssue.response,
          stage: resource.name,
          httpStatus: reply.status,
        );
      }
      return decoded;
    } on CourseFailure {
      rethrow;
    } on FormatException {
      throw const CourseFailure(CourseIssue.response);
    } on Object {
      // Transport exceptions can contain URLs, cookies or raw bodies.
      throw const CourseFailure(CourseIssue.network);
    }
  }

  @override
  Future<CourseAccount> identify(String session) async {
    final data = (await _read(CourseResource.identity, session))['data'];
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw const CourseFailure(CourseIssue.response, stage: 'identity');
    }
    // The official homepage and archive request use data[0].user_id.
    return CourseAccount(courseIdentifier((data.first as Map)['user_id']));
  }

  @override
  Future<CourseListing> list(
    String session,
    CourseAccount account, {
    required bool archived,
  }) async => CourseListing.parse(
    await _read(
      archived ? CourseResource.archived : CourseResource.joined,
      session,
      accountId: account.id,
    ),
    archived: archived,
  );

  @override
  void cancel() => _transport.cancel();
}
