import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/github/github_controller.dart';
import 'package:rainclient/github/github_page.dart';
import 'package:rainclient/main.dart';

import 'github_fakes.dart';

void main() {
  testWidgets('unreadable local connection still offers explicit cleanup', (
    tester,
  ) async {
    final store = MemoryGithubStore(syntheticGithubSaved())..failRead = true;
    final controller = GithubController(
      client: FakeGithubGateway(),
      store: store,
      now: () => githubTestNow,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      RainClientApp(home: GithubPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(controller.phase, GithubPhase.error);
    await tester.ensureVisible(find.byKey(const ValueKey('github-disconnect')));
    await tester.tap(find.byKey(const ValueKey('github-disconnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除本机连接'));
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(controller.phase, GithubPhase.unbound);
  });

  testWidgets(
    'authorization code and cancel are visible without opening a browser',
    (tester) async {
      final api = FakeGithubGateway();
      final controller = GithubController(
        client: api,
        store: MemoryGithubStore(),
        now: () => githubTestNow,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        RainClientApp(home: GithubPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('github-authorize')),
      );
      await tester.tap(find.byKey(const ValueKey('github-authorize')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('github-user-code')), findsOneWidget);
      expect(find.text('ABCD-1234'), findsOneWidget);
      expect(api.pollCount, 0);
      await tester.ensureVisible(find.text('取消本次授权等待'));
      await tester.tap(find.text('取消本次授权等待'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('github-user-code')), findsNothing);
      expect(controller.phase, GithubPhase.unbound);
    },
  );

  testWidgets('repository selection and confirmed local disconnect work', (
    tester,
  ) async {
    final store = MemoryGithubStore(syntheticGithubSaved());
    final controller = GithubController(
      client: FakeGithubGateway(),
      store: store,
      now: () => githubTestNow,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      RainClientApp(home: GithubPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('@frewily'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('github-repository-101')));
    await tester.pumpAndSettle();
    expect(store.value!.selectedRepositoryId, 101);
    await tester.ensureVisible(find.byKey(const ValueKey('github-disconnect')));
    await tester.tap(find.byKey(const ValueKey('github-disconnect')));
    await tester.pumpAndSettle();
    expect(store.value, isNotNull);
    await tester.tap(find.text('清除本机连接'));
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(find.text('尚未连接'), findsOneWidget);
  });
}
