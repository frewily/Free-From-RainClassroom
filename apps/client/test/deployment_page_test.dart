import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/deployment/deployment_page.dart';
import 'package:rainclient/main.dart';
import 'package:rainclient/login_page.dart';

import 'auth_fakes.dart';

import 'deployment_fakes.dart';

void main() {
  testWidgets('full app starts with all four tabs and no credentials', (
    tester,
  ) async {
    final memory = <String, String>{};
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final key = call.arguments['key'] as String?;
          switch (call.method) {
            case 'read':
              return memory[key];
            case 'write':
              memory[key!] = call.arguments['value'];
              return null;
            case 'delete':
              memory.remove(key);
              return null;
            default:
              return null;
          }
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      RainClientApp(
        home: ConnectionHome(
          rainPage: LoginPage(
            store: MemoryStore(),
            verifier: FakeVerifier(),
            cookies: MemoryCookies(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cloudflare'), findsOneWidget);
    expect(find.text('部署验证'), findsOneWidget);
    await tester.tap(find.text('部署验证'));
    await tester.pumpAndSettle();
    expect(find.text('检查并生成测试部署清单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'deployment needs an explicit resource review before any mutation',
    (tester) async {
      final h = DeploymentHarness();
      addTearDown(h.controller.dispose);
      await tester.pumpWidget(
        RainClientApp(home: DeploymentPage(controller: h.controller)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('检查并生成测试部署清单'));
      await tester.pumpAndSettle();
      expect(h.wire.dispatches, 0);
      expect(h.wire.workerUploads, 0);
      await tester.ensureVisible(find.text('确认部署并运行空任务'));
      await tester.tap(find.text('确认部署并运行空任务'));
      await tester.pumpAndSettle();
      expect(find.text('部署并运行本次测试？'), findsOneWidget);
      expect(h.wire.dispatches, 0);
      await tester.tap(find.text('确认执行'));
      await tester.pumpAndSettle();
      expect(h.controller.successful, isTrue);
      expect(h.wire.dispatches, 1);
      expect(h.wire.entry, isFalse);
      expect(find.text('测试链路已跑通'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
