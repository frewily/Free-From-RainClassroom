import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probe/main.dart';

void main() {
  testWidgets(
    'first frame and repeated button actions update visible local state',
    (tester) async {
      await tester.pumpWidget(const EnvironmentProbe());
      expect(find.text('测试程序已打开'), findsOneWidget);
      expect(find.text('按钮已响应 0 次'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('probe-button')));
      await tester.pump();
      expect(find.text('按钮已响应 1 次'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('probe-button')));
      await tester.pump();
      expect(find.text('按钮已响应 2 次'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const EnvironmentProbe());
      expect(find.text('按钮已响应 0 次'), findsOneWidget);
    },
  );
}
