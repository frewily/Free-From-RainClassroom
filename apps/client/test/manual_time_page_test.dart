import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/courses/course_model.dart';
import 'package:rainclient/main.dart';
import 'package:rainclient/timetable/manual_time_controller.dart';
import 'package:rainclient/timetable/manual_time_page.dart';
import 'package:rainclient/timetable/manual_time_store.dart';

import 'course_fakes.dart';

void main() {
  ManualTimeController makeController(CourseMemoryRecord record) =>
      ManualTimeController(
        checkAccess: () async {},
        store: ManualTimeStore(
          const CourseAccount('account-a'),
          'one',
          record: record,
        ),
      );

  testWidgets(
    'access failure hides the previous classroom title as well as times',
    (tester) async {
      final controller = ManualTimeController(
        checkAccess: () async => throw const CourseFailure(CourseIssue.changed),
        store: ManualTimeStore(
          const CourseAccount('account-a'),
          'one',
          record: CourseMemoryRecord(),
        ),
      );
      await tester.pumpWidget(
        RainClientApp(
          home: ManualTimePage(course: course('one'), controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('合成同名课程'), findsNothing);
      expect(find.text('合成班级 one'), findsNothing);
      expect(find.byKey(const ValueKey('time-error')), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('add-class-time')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'weekly preview lists exact dates, then saves only on explicit action',
    (tester) async {
      final record = CourseMemoryRecord();
      final actual = makeController(record);
      await tester.pumpWidget(
        RainClientApp(
          home: ManualTimePage(course: course('one'), controller: actual),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-class-time')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('confirm-class-times')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('time-weekly')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('preview-class-times')));
      await tester.pumpAndSettle();
      expect(actual.entries, isEmpty);
      expect(find.byKey(const ValueKey('class-time-preview')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-class-times')));
      await tester.pumpAndSettle();
      expect(actual.entries.length, 5);
      expect(record.value, isNull);
      await tester.tap(find.byKey(const ValueKey('save-class-times')));
      await tester.pumpAndSettle();
      expect(find.text('本机时间已保存'), findsOneWidget);
      expect((record.value!['entries'] as List).length, 5);
      expect(find.text('手工时间 · 尚未启用监听'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing the repeat option invalidates a previous preview', (
    tester,
  ) async {
    final controller = makeController(CourseMemoryRecord());
    await tester.pumpWidget(
      RainClientApp(
        home: ManualTimePage(course: course('one'), controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-class-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preview-class-times')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('time-weekly')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('class-time-preview')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('confirm-class-times')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'narrow screen and large text keep time page and editor scrollable',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: ManualTimePage(
              course: course('one'),
              controller: makeController(CourseMemoryRecord()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-class-time')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('preview-class-times')),
      );
      await tester.tap(find.byKey(const ValueKey('preview-class-times')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'back navigation asks before discarding a draft and does not write it',
    (tester) async {
      final record = CourseMemoryRecord();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ManualTimePage(
                      course: course('one'),
                      controller: makeController(record),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-class-time')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('preview-class-times')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-class-times')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的时间？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('手工上课时间'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃更改'));
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(record.value, isNull);
    },
  );
}
