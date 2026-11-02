import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../client_support.dart';
import 'course_model.dart';

class CourseSelectionStore {
  CourseSelectionStore({RecordStore Function(CourseAccount)? records})
    : _records =
          records ??
          ((account) => SecureRecordStore(
            'top.frewily.rainclient.dev.courses',
            'selection.${sha256.convert(utf8.encode(account.scope))}',
          ));
  final RecordStore Function(CourseAccount) _records;
  final _work = SerialWork();

  Future<Set<String>> read(CourseAccount account) => _work.run(() async {
    try {
      final value = await _records(account).read();
      if (value == null) return <String>{};
      if (value['version'] != 1 ||
          value['origin'] != courseOrigin ||
          value['accountId'] != account.id ||
          value['selected'] is! List) {
        throw const CourseFailure(CourseIssue.storage);
      }
      final raw = value['selected'] as List;
      if (raw.length > 5000) throw const CourseFailure(CourseIssue.storage);
      final ids = raw.map(courseIdentifier).toSet();
      if (ids.length != raw.length) {
        throw const CourseFailure(CourseIssue.storage);
      }
      return ids;
    } on Object {
      throw const CourseFailure(CourseIssue.storage);
    }
  });

  Future<void> write(CourseAccount account, Set<String> ids) =>
      _work.run(() async {
        try {
          if (ids.length > 5000) throw const CourseFailure(CourseIssue.storage);
          final selected = ids.map(courseIdentifier).toList()..sort();
          final value = {
            'version': 1,
            'origin': courseOrigin,
            'accountId': account.id,
            'selected': selected,
          };
          if (jsonEncode(value).length > 65536) {
            throw const CourseFailure(CourseIssue.storage);
          }
          await _records(account).write(value);
        } on Object {
          throw const CourseFailure(CourseIssue.storage);
        }
      });
}
