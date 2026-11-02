import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/courses/course_controller.dart';
import 'package:rainclient/courses/course_page.dart';
import 'package:rainclient/main.dart';

import 'auth_fakes.dart';
import 'course_fakes.dart';

void main() {
  testWidgets(
    'same-named classes are selected independently and saved explicitly',
    (tester) async {
      final storage = CourseMemoryStorage();
      final controller = CourseController(
        sessions: MemoryStore('synthetic-session'),
        gateway: FakeCourseGateway(),
        selections: storage.store,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        RainClientApp(home: CoursePage(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(controller.listing!.classes.length, 2);
      // Move the row clear of the fixed save footer before tapping its centre.
      await tester.drag(find.byType(ListView), const Offset(0, -220));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('course-one')));
      await tester.tap(find.byKey(const ValueKey('course-one')));
      await tester.pump();
      expect(controller.selected, {'one'});
      expect(controller.dirty, isTrue);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('times-one')))
            .onPressed,
        isNull,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('course-two')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const ValueKey('course-two')))
            .value,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('course-two')));
      await tester.pump();
      expect(controller.selected, {'one', 'two'});
      await tester.tap(find.byKey(const ValueKey('save-course-selection')));
      await tester.pumpAndSettle();
      expect(find.text('选择已保存'), findsOneWidget);
      expect(controller.dirty, isFalse);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('times-two')))
            .onPressed,
        isNotNull,
      );
      expect(find.text('本机选择 · 尚未启用监听'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial results disable editing without displaying an empty-course claim',
    (tester) async {
      final gateway = FakeCourseGateway()..complete = false;
      final controller = CourseController(
        sessions: MemoryStore('synthetic-session'),
        gateway: gateway,
        selections: CourseMemoryStorage().store,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        RainClientApp(home: CoursePage(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('courses-incomplete')), findsOneWidget);
      final tile = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('course-one')),
      );
      expect(tile.onChanged, isNull);
      expect(find.text('当前列表没有课程班级。'), findsNothing);
    },
  );

  testWidgets(
    'narrow screens with large text keep the selection controls usable',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = CourseController(
        sessions: MemoryStore('synthetic-session'),
        gateway: FakeCourseGateway(),
        selections: CourseMemoryStorage().store,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: CoursePage(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('save-course-selection')),
        findsOneWidget,
      );
    },
  );
}
