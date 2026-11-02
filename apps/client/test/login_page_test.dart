import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/login_page.dart';
import 'package:rainclient/main.dart';

import 'auth_fakes.dart';

void main() {
  testWidgets(
    'saved rain login opens course selection without another login flow',
    (tester) async {
      await tester.pumpWidget(
        RainClientApp(
          home: LoginPage(
            store: MemoryStore('synthetic-session'),
            verifier: FakeVerifier(),
            cookies: MemoryCookies(),
            coursesPageBuilder: (_) =>
                const Scaffold(body: Text('synthetic course reader')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('open-courses')));
      await tester.tap(find.byKey(const ValueKey('open-courses')));
      await tester.pumpAndSettle();
      expect(find.text('synthetic course reader'), findsOneWidget);
      expect(find.text('synthetic official login surface'), findsNothing);
    },
  );

  testWidgets('a user can open login, verify, and exit locally', (
    tester,
  ) async {
    final store = MemoryStore();
    final cookies = MemoryCookies();
    await tester.pumpWidget(
      RainClientApp(
        home: LoginPage(
          store: store,
          verifier: FakeVerifier(),
          cookies: cookies,
          loginViewBuilder: (_) =>
              const Center(child: Text('synthetic official login surface')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还未登录'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('primary-login-action')),
    );
    await tester.tap(find.byKey(const ValueKey('primary-login-action')));
    await tester.pumpAndSettle();
    expect(find.text('synthetic official login surface'), findsOneWidget);
    cookies.candidate = 'synthetic_session';
    await tester.tap(find.byKey(const ValueKey('check-login')));
    await tester.pumpAndSettle();
    expect(find.text('已登录'), findsOneWidget);
    expect(store.value, 'synthetic_session');
    await tester.ensureVisible(find.byKey(const ValueKey('local-logout')));
    await tester.tap(find.byKey(const ValueKey('local-logout')));
    await tester.pumpAndSettle();
    expect(find.text('还未登录'), findsOneWidget);
    expect(store.value, isNull);
  });

  testWidgets('cancelling returns to the previous local state', (tester) async {
    await tester.pumpWidget(
      RainClientApp(
        home: LoginPage(
          store: MemoryStore(),
          verifier: FakeVerifier(),
          cookies: MemoryCookies(),
          loginViewBuilder: (_) => const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('primary-login-action')),
    );
    await tester.tap(find.byKey(const ValueKey('primary-login-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消本次登录'));
    await tester.pumpAndSettle();
    expect(find.text('还未登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
