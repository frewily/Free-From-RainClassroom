import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/client_support.dart';
import 'package:rainclient/courses/course_client.dart';
import 'package:rainclient/courses/course_model.dart';

class FakeCourseTransport extends CourseTransport {
  Object? error;
  int status = 200;
  Object payload = {
    'errcode': 0,
    'data': {'list': []},
  };
  final requests = <CourseResource>[];
  @override
  Future<WireReply> get(
    CourseResource resource,
    String session, {
    String? accountId,
  }) async {
    requests.add(resource);
    if (error != null) throw error!;
    return WireReply(status, jsonEncode(payload));
  }
}

Map<String, dynamic> row(String id, {bool archived = false}) => {
  if (archived) 'id': id else 'classroom_id': id,
  'name': '合成班级 $id',
  'course': {'id': 'course-$id', 'name': '合成同名课程'},
  'teacher': {'name': '合成教师'},
  'role': 6,
};

void main() {
  test(
    'fixed endpoints only read identity, joined student classes and archives',
    () {
      expect(
        DartCourseTransport.endpoint(CourseResource.identity).toString(),
        '$courseOrigin/v2/api/web/userinfo',
      );
      expect(
        DartCourseTransport.endpoint(CourseResource.joined).queryParameters,
        {'identity': '2'},
      );
      expect(
        DartCourseTransport.endpoint(
          CourseResource.archived,
          accountId: 'account-a',
        ).queryParameters,
        {'user_id': 'account-a'},
      );
      expect(
        () => DartCourseTransport.endpoint(
          CourseResource.archived,
          accountId: '../other',
        ),
        throwsA(isA<CourseFailure>()),
      );
    },
  );

  test(
    'identity is the archive user_id, not a guessed profile identifier',
    () async {
      final wire = FakeCourseTransport()
        ..payload = {
          'errcode': 0,
          'data': [
            {'id': 'different', 'user_id': 123},
          ],
        };
      expect(
        (await CourseClient(transport: wire).identify('synthetic-session')).id,
        '123',
      );
      wire.payload = {
        'errcode': 0,
        'data': [
          {'id': 123},
        ],
      };
      await expectLater(
        CourseClient(transport: wire).identify('synthetic-session'),
        throwsA(isA<CourseFailure>()),
      );
    },
  );

  test(
    'all 35 classes survive and same names keep distinct classroom identities',
    () async {
      final wire = FakeCourseTransport()
        ..payload = {
          'errcode': 0,
          'data': {'list': List.generate(35, (i) => row('$i'))},
        };
      final result = await CourseClient(transport: wire)
          .list('synthetic-session', const CourseAccount('a'), archived: false);
      expect(result.classes.length, 35);
      expect(result.classes.map((c) => c.id).toSet().length, 35);
      expect(result.classes.first.term, isNull);
      expect(result.classes.first.role, 6);
      expect(result.complete, isTrue);
      expect(wire.requests, [CourseResource.joined]);
    },
  );

  test(
    'archive uses its observed id field and leaves unknown terms unknown',
    () {
      final listing = CourseListing.parse({
        'data': {
          'classrooms': [
            {
              ...row('archive', archived: true),
              'classroom_id': 'unused',
              'course_id': 'known-course',
              'term': 0,
            },
          ],
        },
      }, archived: true);
      expect(listing.classes.single.id, 'archive');
      expect(listing.classes.single.courseId, 'known-course');
      expect(listing.classes.single.term, isNull);
    },
  );

  test(
    'a pagination signal is partial and never follows a supplied URL',
    () async {
      final wire = FakeCourseTransport()
        ..payload = {
          'errcode': 0,
          'data': {
            'list': [row('one')],
            'has_more': true,
            'next': 'https://untrusted.invalid/private',
          },
        };
      final listing = await CourseClient(transport: wire)
          .list('synthetic-session', const CourseAccount('a'), archived: false);
      expect(listing.complete, isFalse);
      expect(wire.requests, [CourseResource.joined]);
      expect(
        CourseListing.parse({
          'data': {'list': [], 'total': 2},
        }, archived: false).complete,
        isFalse,
      );
    },
  );

  test('malformed rows or duplicate classrooms fail the whole read', () {
    for (final rows in [
      [
        row('one'),
        {'name': 'broken'},
      ],
      [row('one'), row('one')],
      [
        {...row('one'), 'classroom_id': 1.5},
      ],
    ]) {
      expect(
        () => CourseListing.parse({
          'data': {'list': rows},
        }, archived: false),
        throwsA(isA<CourseFailure>()),
      );
    }
  });

  test('known expiry is separate from server errors, redirects and network failures', () async {
    final wire = FakeCourseTransport()
      ..status = 401
      ..payload = {'errcode': 401002};
    final client = CourseClient(transport: wire);
    final login = isA<CourseFailure>().having(
      (e) => e.issue,
      'issue',
      CourseIssue.login,
    );
    await expectLater(client.identify('synthetic-session'), throwsA(login));
    wire.status = 500;
    await expectLater(
      client.identify('synthetic-session'),
      throwsA(
        isA<CourseFailure>().having(
          (e) => e.issue,
          'issue',
          CourseIssue.response,
        ),
      ),
    );
    wire.status = 302;
    await expectLater(
      client.identify('synthetic-session'),
      throwsA(isA<CourseFailure>()),
    );
    wire.error = StateError('private-cookie-and-response');
    try {
      await client.identify('synthetic-session');
      fail('must fail');
    } on CourseFailure catch (error) {
      expect(error.issue, CourseIssue.network);
      expect('$error', isNot(contains('private-cookie')));
    }
    final before = wire.requests.length;
    await expectLater(client.identify('unsafe;session'), throwsA(login));
    expect(wire.requests.length, before);
  });
}
