enum CourseIssue { login, network, response, storage, changed }

class CourseFailure implements Exception {
  const CourseFailure(this.issue, {this.stage = '', this.httpStatus});
  final CourseIssue issue;
  final String stage;
  final int? httpStatus;
}

const courseOrigin = 'https://changjiang.yuketang.cn';

String courseIdentifier(Object? value) {
  final text = value is int
      ? '$value'
      : value is String
      ? value
      : '';
  if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(text)) {
    throw const CourseFailure(CourseIssue.response, stage: 'identifier');
  }
  return text;
}

String? _optionalIdentifier(Object? value) =>
    value == null ? null : courseIdentifier(value);

String _label(Object? value, {bool required = false}) {
  if (value == null && !required) return '';
  if (value is! String ||
      value.length > 1024 ||
      (required && value.trim().isEmpty)) {
    throw const CourseFailure(CourseIssue.response, stage: 'classroom');
  }
  return value.trim();
}

class CourseAccount {
  const CourseAccount(this.id);
  final String id;
  String get scope => '$courseOrigin\n$id';
}

class CourseClass {
  const CourseClass({
    required this.id,
    required this.name,
    required this.className,
    this.courseId,
    this.term,
    this.teacher = '',
    this.role,
    required this.archived,
  });
  final String id, name, className, teacher;
  final String? courseId, term;
  final int? role;
  final bool archived;

  factory CourseClass.parse(Object? value, {required bool archived}) {
    if (value is! Map<String, dynamic> ||
        value['course'] is! Map<String, dynamic>) {
      throw const CourseFailure(CourseIssue.response, stage: 'classroom');
    }
    final course = value['course'] as Map<String, dynamic>;
    final teacher = value['teacher'];
    final rawRole = value['role'];
    final role = rawRole is int
        ? rawRole
        : rawRole is String
        ? int.tryParse(rawRole)
        : null;
    final rawTerm = value['term'];
    // Keep the provider's term opaque: its season mapping varies by course type.
    final term = rawTerm == null || rawTerm == 0 || rawTerm == '0'
        ? null
        : _optionalIdentifier(rawTerm);
    return CourseClass(
      // Official archive cards use id; joined student cards use classroom_id.
      id: courseIdentifier(value[archived ? 'id' : 'classroom_id']),
      name: _label(course['name'], required: true),
      className: _label(value['name']),
      courseId: _optionalIdentifier(value['course_id'] ?? course['id']),
      term: term,
      teacher: teacher is Map ? _label(teacher['name']) : '',
      role: role,
      archived: archived,
    );
  }
}

class CourseListing {
  CourseListing({
    required List<CourseClass> classes,
    required this.complete,
    required this.archived,
  }) : classes = List.unmodifiable(classes);
  final List<CourseClass> classes;
  final bool complete, archived;

  factory CourseListing.parse(
    Map<String, dynamic> payload, {
    required bool archived,
  }) {
    final data = payload['data'];
    if (data is! Map<String, dynamic>) {
      throw const CourseFailure(CourseIssue.response, stage: 'list');
    }
    final rows = data[archived ? 'classrooms' : 'list'];
    if (rows is! List || rows.length > 5000) {
      throw const CourseFailure(CourseIssue.response, stage: 'list');
    }
    final classes = rows
        .map((r) => CourseClass.parse(r, archived: archived))
        .toList();
    if (classes.map((c) => c.id).toSet().length != classes.length) {
      throw const CourseFailure(CourseIssue.response, stage: 'duplicate');
    }
    var complete = true;
    for (final container in [payload, data]) {
      for (final key in ['has_more', 'hasMore']) {
        if (container.containsKey(key)) {
          final more = container[key];
          if (more is! bool) {
            throw const CourseFailure(
              CourseIssue.response,
              stage: 'pagination',
            );
          }
          if (more) complete = false;
        }
      }
      if (container['next'] != null && container['next'] != '') {
        complete = false;
      }
    }
    final total = data['total'];
    if (total != null) {
      if (total is! int || total < classes.length) {
        throw const CourseFailure(CourseIssue.response, stage: 'pagination');
      }
      if (total > classes.length) complete = false;
    }
    return CourseListing(
      classes: classes,
      complete: complete,
      archived: archived,
    );
  }
}
