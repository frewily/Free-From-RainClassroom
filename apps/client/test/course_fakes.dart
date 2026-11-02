import 'dart:async';

import 'package:rainclient/client_support.dart';
import 'package:rainclient/courses/course_client.dart';
import 'package:rainclient/courses/course_model.dart';
import 'package:rainclient/courses/course_store.dart';

CourseClass course(
  String id, {
  String name = '合成同名课程',
  bool archived = false,
}) => CourseClass(
  id: id,
  name: name,
  className: '合成班级 $id',
  teacher: '合成教师',
  courseId: 'course-$id',
  archived: archived,
);

CourseListing courseList({bool archived = false, bool complete = true}) =>
    CourseListing(
      classes: [
        course(archived ? 'old' : 'one', archived: archived),
        course(archived ? 'older' : 'two', archived: archived),
      ],
      archived: archived,
      complete: complete,
    );

class FakeCourseGateway extends CourseGateway {
  CourseAccount owner = const CourseAccount('account-a');
  CourseFailure? error;
  Completer<CourseListing>? listGate;
  var listStarted = Completer<void>();
  int identities = 0, lists = 0, cancellations = 0;
  bool complete = true;
  @override
  Future<CourseAccount> identify(String session) async {
    identities++;
    if (error != null) throw error!;
    return owner;
  }

  @override
  Future<CourseListing> list(
    String session,
    CourseAccount account, {
    required bool archived,
  }) async {
    lists++;
    if (!listStarted.isCompleted) listStarted.complete();
    return listGate?.future ??
        courseList(archived: archived, complete: complete);
  }

  @override
  void cancel() => cancellations++;
}

class CourseMemoryRecord implements RecordStore {
  Map<String, dynamic>? value;
  bool failWrite = false;
  Completer<void>? writeGate;
  final writeStarted = Completer<void>();
  @override
  Future<Map<String, dynamic>?> read() async => value;
  @override
  Future<void> write(Map<String, dynamic> data) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    if (writeGate != null) await writeGate!.future;
    if (failWrite) throw StateError('synthetic storage error');
    value = Map.of(data);
  }

  @override
  Future<void> delete() async => value = null;
}

class CourseMemoryStorage {
  final records = <String, CourseMemoryRecord>{};
  CourseMemoryRecord record(CourseAccount account) =>
      records.putIfAbsent(account.scope, CourseMemoryRecord.new);
  CourseSelectionStore get store => CourseSelectionStore(records: record);
  void seed(String owner, List<String> ids) {
    record(CourseAccount(owner)).value = {
      'version': 1,
      'origin': courseOrigin,
      'accountId': owner,
      'selected': ids,
    };
  }
}
