import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/pages/auth/login_page.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Makes secure storage answer `last_user_id` with [lastUserId].
  void storedLastUser(String? lastUserId) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        if (call.method == 'read' &&
            (call.arguments as Map)['key'] == 'last_user_id') {
          return lastUserId;
        }
        return null;
      },
    );
    for (final name in [
      'com.llfbandit.app_links/messages',
      'com.llfbandit.app_links/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
  }

  Future<void> showSignIn(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => AuthState()),
        ],
        child: MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: const LoginPage(),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('a first-time user is not welcomed back', (tester) async {
    storedLastUser(null);
    await showSignIn(tester);
    expect(find.text('Sign in to Elephant'), findsOneWidget);
    expect(find.text('Welcome back'), findsNothing);
  });

  testWidgets('someone who signed in here before is welcomed back', (
    tester,
  ) async {
    storedLastUser('11111111-2222-3333-4444-555555555555');
    await showSignIn(tester);
    expect(find.text('Welcome back'), findsOneWidget);
  });
}
