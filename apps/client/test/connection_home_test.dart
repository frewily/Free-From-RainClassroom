import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/github/github_controller.dart';
import 'package:rainclient/github/github_page.dart';
import 'package:rainclient/login_page.dart';
import 'package:rainclient/main.dart';

import 'auth_fakes.dart';
import 'github_fakes.dart';

void main() {
  testWidgets('clearing GitHub and switching tabs keeps rain login intact', (
    tester,
  ) async {
    final rain = MemoryStore('synthetic_rain_session');
    final github = MemoryGithubStore(syntheticGithubSaved());
    final controller = GithubController(
      client: FakeGithubGateway(),
      store: github,
      now: () => githubTestNow,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      RainClientApp(
        home: ConnectionHome(
          rainPage: LoginPage(
            store: rain,
            verifier: FakeVerifier(),
            cookies: MemoryCookies(),
          ),
          githubPage: GithubPage(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已登录'), findsOneWidget);
    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();
    expect(find.text('@frewily'), findsOneWidget);
    await controller.disconnect();
    await tester.pumpAndSettle();
    await tester.tap(find.text('雨课堂'));
    await tester.pumpAndSettle();
    expect(find.text('已登录'), findsOneWidget);
    expect(rain.value, 'synthetic_rain_session');
    expect(github.value, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rain local logout leaves GitHub connection intact', (
    tester,
  ) async {
    final rain = MemoryStore('synthetic_rain_session');
    final github = MemoryGithubStore(syntheticGithubSaved(selected: 101));
    final controller = GithubController(
      client: FakeGithubGateway(),
      store: github,
      now: () => githubTestNow,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      RainClientApp(
        home: ConnectionHome(
          rainPage: LoginPage(
            store: rain,
            verifier: FakeVerifier(),
            cookies: MemoryCookies(),
          ),
          githubPage: GithubPage(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('local-logout')));
    await tester.tap(find.byKey(const ValueKey('local-logout')));
    await tester.pumpAndSettle();
    expect(rain.value, isNull);
    expect(github.value!.selectedRepositoryId, 101);
    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();
    expect(find.text('@frewily'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
