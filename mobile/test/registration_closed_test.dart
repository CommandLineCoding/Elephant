import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/pages/auth/login_page.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answers every request with [body] (or fails when it is null).
class _FakeHealth implements HttpClientAdapter {
  Object? body;
  int status = 200;
  _FakeHealth(this.body);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (body == null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

AuthState _authWith(_FakeHealth health) =>
    AuthState(healthClient: Dio()..httpClientAdapter = health);

Map<String, dynamic> _health(String? registration) => {
  'success': true,
  'data': {'postgres': 'up', 'registration': ?registration},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'com.llfbandit.app_links/messages',
      'com.llfbandit.app_links/events',
      'plugins.it_nomads.com/flutter_secure_storage',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
  });

  group('AuthState.isRegistrationClosed', () {
    test('reads data.registration', () {
      expect(AuthState.isRegistrationClosed(_health('closed')), isTrue);
      expect(AuthState.isRegistrationClosed(_health('open')), isFalse);
    });

    test('treats a missing or malformed field as open', () {
      expect(AuthState.isRegistrationClosed(_health(null)), isFalse);
      expect(AuthState.isRegistrationClosed({'data': 'closed'}), isFalse);
      expect(AuthState.isRegistrationClosed('closed'), isFalse);
      expect(AuthState.isRegistrationClosed(null), isFalse);
    });
  });

  group('AuthState.refreshRegistrationStatus', () {
    test('closes registration when the server says so', () async {
      final auth = _authWith(_FakeHealth(_health('closed')));
      await auth.refreshRegistrationStatus();
      expect(auth.registrationClosed, isTrue);
    });

    test('stays open for an older server without the field', () async {
      final auth = _authWith(_FakeHealth(_health(null)));
      await auth.refreshRegistrationStatus();
      expect(auth.registrationClosed, isFalse);
    });

    test('stays open when the server is unreachable', () async {
      final auth = _authWith(_FakeHealth(null));
      await auth.refreshRegistrationStatus();
      expect(auth.registrationClosed, isFalse);
    });

    test('reopens when a later check says open', () async {
      final health = _FakeHealth(_health('closed'));
      final auth = _authWith(health);
      await auth.refreshRegistrationStatus();
      health.body = _health('open');
      await auth.refreshRegistrationStatus();
      expect(auth.registrationClosed, isFalse);
    });
  });

  test('a refused registration shows the server message', () {
    final options = RequestOptions(path: '/auth/register');
    final error = DioException(
      requestOptions: options,
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: options,
        statusCode: 403,
        data: {
          'success': false,
          'error': 'Registration is closed on this server',
        },
      ),
    );
    expect(
      ApiService.errorMessage(error, fallback: 'Registration failed'),
      'Registration is closed on this server',
    );
  });

  group('login page', () {
    Future<void> show(WidgetTester tester, AuthState auth) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(390, 844) * 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider.value(value: auth),
          ],
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.values.first),
            home: const LoginPage(),
          ),
        ),
      );
      // The health request started in initState needs real async to finish.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(seconds: 2));
    }

    testWidgets('hides Register and explains why on a closed server', (
      tester,
    ) async {
      await show(tester, _authWith(_FakeHealth(_health('closed'))));
      expect(find.text('Register'), findsNothing);
      expect(find.text("This server isn't accepting new accounts."), findsOne);
      expect(find.text('Sign in'), findsWidgets);
      // Existing accounts can still sign in with Google or GitHub.
      expect(find.text('Google'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows Register on an open server', (tester) async {
      await show(tester, _authWith(_FakeHealth(_health('open'))));
      expect(find.text('Register'), findsOneWidget);
      expect(find.textContaining('accepting new accounts'), findsNothing);
    });

    testWidgets('leaves the Register form when the server closes', (
      tester,
    ) async {
      final health = _FakeHealth(_health('open'));
      final auth = _authWith(health);
      await show(tester, auth);
      await tester.tap(find.text('Register'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Create account'), findsOneWidget);

      health.body = _health('closed');
      await tester.runAsync(auth.refreshRegistrationStatus);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Create account'), findsNothing);
      expect(find.text('Sign in'), findsWidgets);
    });
  });
}
