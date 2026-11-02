import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/courses/course_model.dart';
import 'package:rainclient/timetable/manual_time.dart';
import 'package:rainclient/timetable/manual_time_controller.dart';
import 'package:rainclient/timetable/manual_time_store.dart';

import 'course_fakes.dart';

ManualClassTime slot(String date, [int start = 480, int end = 580]) =>
    ManualClassTime(date: date, start: start, end: end);

void main() {
  test(
    'weekly generation is inclusive and materializes exact calendar dates',
    () {
      final dates = ManualClassTime.generate(
        firstDate: '2026-11-02',
        start: 480,
        end: 580,
        weeklyUntil: '2026-11-17',
      );
      expect(dates.map((e) => e.date), [
        '2026-11-02',
        '2026-11-09',
        '2026-11-16',
      ]);
      expect(
        ManualClassTime.generate(
          firstDate: '2026-11-02',
          start: 480,
          end: 580,
          weeklyUntil: '2026-11-09',
        ).length,
        2,
      );
      expect(
        ManualClassTime.generate(
          firstDate: '2026-11-02',
          start: 480,
          end: 580,
        ).length,
        1,
      );
      expect(slot('2026-11-02').label, '2026-11-02  08:00–09:40');
    },
  );

  test('calendar arithmetic crosses leap day and year without local timezone conversion', () {
    expect(
      ManualClassTime.generate(
        firstDate: '2028-02-22',
        start: 0,
        end: 1,
        weeklyUntil: '2028-03-07',
      ).map((e) => e.date),
      ['2028-02-22', '2028-02-29', '2028-03-07'],
    );
    expect(
      ManualClassTime.generate(
        firstDate: '2026-12-28',
        start: 480,
        end: 580,
        weeklyUntil: '2027-01-04',
      ).map((e) => e.date),
      ['2026-12-28', '2027-01-04'],
    );
    expect(manualTimeZone, 'Asia/Shanghai');
  });

  test('invalid dates, reverse or overnight clocks and excessive repeat range fail', () {
    for (final date in [
      '2026-02-29',
      '2026-13-01',
      '2026-2-01',
      '1999-12-31',
      '2101-01-01',
    ]) {
      expect(() => slot(date), throwsA(isA<TimeInputFailure>()));
    }
    for (final clocks in [
      [580, 480],
      [480, 480],
      [-1, 100],
      [1380, 1440],
    ]) {
      expect(
        () => slot('2026-11-02', clocks[0], clocks[1]),
        throwsA(isA<TimeInputFailure>()),
      );
    }
    for (final until in ['2026-11-01', '2027-11-03']) {
      expect(
        () => ManualClassTime.generate(
          firstDate: '2026-11-02',
          start: 480,
          end: 580,
          weeklyUntil: until,
        ),
        throwsA(isA<TimeInputFailure>()),
      );
    }
  });

  test(
    'duplicate and overlapping periods are refused; adjacent periods are valid',
    () {
      expect(
        () => validateClassTimes([slot('2026-11-02'), slot('2026-11-02')]),
        throwsA(isA<TimeInputFailure>()),
      );
      expect(
        () => validateClassTimes([
          slot('2026-11-02'),
          slot('2026-11-02', 570, 600),
        ]),
        throwsA(isA<TimeInputFailure>()),
      );
      expect(
        validateClassTimes([
          slot('2026-11-03'),
          slot('2026-11-02', 580, 600),
          slot('2026-11-02'),
        ]).map((e) => e.key),
        ['2026-11-02/480/580', '2026-11-02/580/600', '2026-11-03/480/580'],
      );
    },
  );

  test(
    'the 200 occurrence limit refuses the whole plan without truncating',
    () {
      final dates = List.generate(
        201,
        (i) => slot(
          formatClassDate(DateTime.utc(2026, 1, 1).add(Duration(days: i))),
        ),
      );
      expect(() => validateClassTimes(dates), throwsA(isA<TimeInputFailure>()));
      expect(validateClassTimes(dates.take(200)).length, 200);
    },
  );

  late CourseMemoryRecord record;
  late ManualTimeStore store;
  late ManualTimeController controller;
  var allowed = true;
  setUp(() {
    record = CourseMemoryRecord();
    store = ManualTimeStore(
      const CourseAccount('account-a'),
      'one',
      record: record,
    );
    allowed = true;
    controller = ManualTimeController(
      checkAccess: () async {
        if (!allowed) throw const CourseFailure(CourseIssue.changed);
      },
      store: store,
    );
  });
  tearDown(() => controller.dispose());

  test(
    'encrypted record contract round-trips only manual dates and ownership',
    () async {
      await store.write([slot('2026-11-02')]);
      expect(record.value!['source'], 'manual');
      expect(record.value!['timezone'], 'Asia/Shanghai');
      expect(record.value!['entries'], [
        {'date': '2026-11-02', 'start': 480, 'end': 580},
      ]);
      expect((await store.read()).single.key, '2026-11-02/480/580');
      expect(record.value!.containsKey('session'), isFalse);
    },
  );

  test('wrong account, classroom, timezone, version and malformed data are not overwritten', () async {
    await store.write([slot('2026-11-02')]);
    final valid = Map<String, dynamic>.of(record.value!);
    for (final change in [
      {'accountId': 'account-b'},
      {'classroomId': 'two'},
      {'timezone': 'UTC'},
      {'version': 2},
      {
        'entries': [
          {'date': '2026-02-30', 'start': 480, 'end': 580},
        ],
      },
    ]) {
      record.value = {...valid, ...change};
      await expectLater(store.read(), throwsA(isA<ManualTimeStorageFailure>()));
      expect(record.value, {...valid, ...change});
    }
  });

  test(
    'edit and delete affect one materialized occurrence and save explicitly',
    () async {
      await store.write(
        ManualClassTime.generate(
          firstDate: '2026-11-02',
          start: 480,
          end: 580,
          weeklyUntil: '2026-11-16',
        ),
      );
      await controller.load();
      final old = controller.entries[1];
      controller.replace(old: old, additions: [slot('2026-11-09', 600, 660)]);
      controller.remove(controller.entries.first);
      expect(controller.entries.map((e) => e.key), [
        '2026-11-09/600/660',
        '2026-11-16/480/580',
      ]);
      expect((record.value!['entries'] as List).length, 3);
      await controller.save();
      expect(controller.dirty, isFalse);
      expect((await store.read()).length, 2);
    },
  );

  test(
    'a conflicting batch is rejected in full and preserves the previous draft',
    () async {
      await controller.load();
      controller.replace(additions: [slot('2026-11-09')]);
      expect(
        controller.replace(
          additions: ManualClassTime.generate(
            firstDate: '2026-11-02',
            start: 480,
            end: 580,
            weeklyUntil: '2026-11-16',
          ),
        ),
        isFalse,
      );
      expect(controller.entries.map((e) => e.date), ['2026-11-09']);
      expect(record.value, isNull);
    },
  );

  test('write failure retains draft and never marks it saved; retry and clear restore', () async {
    await controller.load();
    controller.replace(additions: [slot('2026-11-02')]);
    record.failWrite = true;
    await controller.save();
    expect(controller.error, isNotNull);
    expect(controller.dirty, isTrue);
    expect(record.value, isNull);
    record.failWrite = false;
    await controller.save();
    expect(controller.dirty, isFalse);
    controller.remove(controller.entries.single);
    await controller.save();
    expect(await store.read(), isEmpty);
  });

  test(
    'corrupt storage cannot be replaced by an initially empty page',
    () async {
      record.value = {'version': 'broken'};
      await controller.load();
      expect(controller.canEdit, isFalse);
      controller.replace(additions: [slot('2026-11-02')]);
      await controller.save();
      expect(record.value, {'version': 'broken'});
    },
  );

  test('changed access before save hides data and refuses write', () async {
    await controller.load();
    controller.replace(additions: [slot('2026-11-02')]);
    allowed = false;
    await controller.save();
    expect(controller.blocked, isTrue);
    expect(controller.entries, isEmpty);
    expect(record.value, isNull);
  });

  test(
    'access rotation during a failed write also hides the prior account',
    () async {
      await controller.load();
      controller.replace(additions: [slot('2026-11-02')]);
      record.writeGate = Completer<void>();
      record.failWrite = true;
      final save = controller.save();
      await record.writeStarted.future;
      allowed = false;
      record.writeGate!.complete();
      await save;
      expect(controller.blocked, isTrue);
      expect(controller.entries, isEmpty);
    },
  );

  test('in-flight save stays scoped to its original record and does not claim success after rotation', () async {
    await controller.load();
    controller.replace(additions: [slot('2026-11-02')]);
    record.writeGate = Completer<void>();
    final save = controller.save();
    await record.writeStarted.future;
    allowed = false;
    record.writeGate!.complete();
    await save;
    expect(record.value!['accountId'], 'account-a');
    expect(record.value!['classroomId'], 'one');
    expect(controller.blocked, isTrue);
    expect(controller.entries, isEmpty);
  });
}
