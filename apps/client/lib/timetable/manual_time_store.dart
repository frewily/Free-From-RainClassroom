import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../client_support.dart';
import '../courses/course_model.dart';
import 'manual_time.dart';

class ManualTimeStorageFailure implements Exception {
  const ManualTimeStorageFailure();
}

class ManualTimeStore {
  ManualTimeStore(
    CourseAccount account,
    String classroomId, {
    RecordStore? record,
  }) : _account = account,
       _classroomId = courseIdentifier(classroomId),
       _record =
           record ??
           SecureRecordStore(
             'top.frewily.rainclient.dev.manual-times',
             'times.${sha256.convert(utf8.encode('${account.scope}\n${courseIdentifier(classroomId)}'))}',
           );
  final CourseAccount _account;
  final String _classroomId;
  final RecordStore _record;
  final _work = SerialWork();

  Future<List<ManualClassTime>> read() => _work.run(() async {
    try {
      final value = await _record.read();
      if (value == null) return <ManualClassTime>[];
      if (value['version'] != 1 ||
          value['origin'] != courseOrigin ||
          value['accountId'] != _account.id ||
          value['classroomId'] != _classroomId ||
          value['timezone'] != manualTimeZone ||
          value['source'] != 'manual' ||
          value['entries'] is! List) {
        throw const ManualTimeStorageFailure();
      }
      final rows = value['entries'] as List;
      if (rows.length > maxClassTimes) throw const ManualTimeStorageFailure();
      return validateClassTimes(rows.map(ManualClassTime.fromJson));
    } on Object {
      throw const ManualTimeStorageFailure();
    }
  });

  Future<void> write(List<ManualClassTime> entries) => _work.run(() async {
    final valid = validateClassTimes(entries);
    final value = {
      'version': 1,
      'origin': courseOrigin,
      'accountId': _account.id,
      'classroomId': _classroomId,
      'timezone': manualTimeZone,
      'source': 'manual',
      'entries': valid.map((e) => e.toJson()).toList(),
    };
    if (jsonEncode(value).length > 65536) {
      throw const ManualTimeStorageFailure();
    }
    try {
      await _record.write(value);
    } on Object {
      throw const ManualTimeStorageFailure();
    }
  });
}
