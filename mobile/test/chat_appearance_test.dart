import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/chat_wallpaper.dart';
import 'package:mobile/pages/settings/appearance.dart';
import 'package:mobile/pages/settings/chat_wallpaper.dart';
import 'package:mobile/services/chat_appearance.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_harness.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChatAppearance.instance = ChatAppearance();
  });
  tearDown(() => ChatAppearance.instance = ChatAppearance());

  group('the choices', () {
    test('start at plain and the default size', () async {
      final a = ChatAppearance();
      await a.load();
      expect(a.wallpaper.id, 'none');
      expect(a.wallpaperFor('c1').id, 'none');
      expect(a.textSize, MessageTextSize.standard);
    });

    test('are remembered', () async {
      final a = ChatAppearance();
      await a.setTextSize(MessageTextSize.large);
      await a.setWallpaper(Wallpaper.byId('dots'));
      await a.setWallpaperFor('C1', Wallpaper.byId('rose'));

      final later = ChatAppearance();
      await later.load();
      expect(later.textSize, MessageTextSize.large);
      expect(later.wallpaper.id, 'dots');
      expect(
        later.wallpaperFor('c1').id,
        'rose',
        reason: 'ids are not case sensitive',
      );
      expect(
        later.wallpaperFor('c2').id,
        'dots',
        reason: 'others use the one for all',
      );
      expect(later.hasOwnWallpaper('c1'), isTrue);
      expect(later.hasOwnWallpaper('c2'), isFalse);
    });

    test('a chat can go back to the one for all chats', () async {
      final a = ChatAppearance();
      await a.setWallpaper(Wallpaper.byId('sky'));
      await a.setWallpaperFor('c1', Wallpaper.byId('rose'));
      await a.setWallpaperFor('c1', null);
      expect(a.wallpaperFor('c1').id, 'sky');
      final later = ChatAppearance();
      await later.load();
      expect(later.hasOwnWallpaper('c1'), isFalse);
    });

    test(
      'an unknown wallpaper or size falls back to plain and default',
      () async {
        SharedPreferences.setMockInitialValues({
          'chat_wallpaper': 'from-a-newer-version',
          'message_text_size': 'gigantic',
          'chat_wallpapers': '{"c1": "also-unknown"}',
        });
        final a = ChatAppearance();
        await a.load();
        expect(a.wallpaper.id, 'none');
        expect(a.textSize, MessageTextSize.standard);
        expect(a.wallpaperFor('c1').id, 'none');
      },
    );

    test('a damaged saved value is the same as none', () async {
      SharedPreferences.setMockInitialValues({'chat_wallpapers': '{not json'});
      final a = ChatAppearance();
      await a.load();
      expect(a.hasOwnWallpaper('c1'), isFalse);
    });

    test('the chats\' own wallpapers go on sign-out, the rest stays', () async {
      final a = ChatAppearance();
      await a.setWallpaper(Wallpaper.byId('sky'));
      await a.setTextSize(MessageTextSize.larger);
      await a.setWallpaperFor('c1', Wallpaper.byId('rose'));
      a.forgetChats();
      await Future<void>.delayed(Duration.zero);
      expect(a.hasOwnWallpaper('c1'), isFalse);
      expect(a.wallpaper.id, 'sky');
      expect(a.textSize, MessageTextSize.larger);
      expect(
        (await SharedPreferences.getInstance()).getString('chat_wallpapers'),
        isNull,
      );
    });

    test('the sizes get bigger one after the other', () {
      final scales = MessageTextSize.values.map((s) => s.scale).toList();
      expect(scales, [...scales]..sort());
      expect(MessageTextSize.standard.scale, 1.0);
      expect(scales.toSet().length, scales.length);
    });

    test('every wallpaper has its own ID', () {
      final ids = Wallpaper.all.map((w) => w.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(Wallpaper.all.first, Wallpaper.none);
    });
  });

  // The wallpaper is a light wash and a faint pattern over the theme's own
  // background, so what is written on it must still be easy to read, in
  // every theme.
  group('readability', () {
    for (final type in ThemeType.values) {
      test('in the ${type.name} theme', () {
        final theme = AppThemes.getTheme(type);
        final base = theme.scaffoldBackgroundColor;
        final text = theme.colorScheme.onSurface;
        final quiet = theme.colorScheme.onSurfaceVariant;
        for (final w in Wallpaper.all) {
          final bg = w.background(base);
          expect(
            contrast(text, bg),
            greaterThanOrEqualTo(4.5),
            reason: '${w.name}: text on ${type.name}',
          );
          expect(
            contrast(quiet, bg),
            greaterThanOrEqualTo(3.0),
            reason: '${w.name}: secondary text on ${type.name}',
          );
          // And where a pattern's lines cross it.
          final lines = Color.alphaBlend(
            text.withValues(alpha: Wallpaper.patternStrength),
            bg,
          );
          expect(
            contrast(text, lines),
            greaterThanOrEqualTo(4.5),
            reason: '${w.name}: text on its pattern in ${type.name}',
          );
        }
      });
    }

    test('a wallpaper changes the background, and plain does not', () {
      const base = Color(0xFFF5F7FA);
      expect(Wallpaper.none.background(base), base);
      expect(Wallpaper.byId('sky').background(base), isNot(base));
    });
  });

  group('the screens', () {
    Widget app(Widget home) => MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => ThemeProvider())],
      child: MaterialApp(
        theme: AppThemes.getTheme(ThemeType.frost),
        home: home,
      ),
    );

    testWidgets('Appearance shows the wallpaper and the text size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 2400);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(const AppearanceSettings()));
      await tester.pumpAndSettle();
      expect(find.text('Chat wallpaper'), findsOneWidget);
      expect(find.text('Plain'), findsOneWidget);
      expect(find.text('Message text size'), findsOneWidget);
      expect(find.text('Default'), findsOneWidget);

      await tester.tap(find.text('Message text size'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Larger'));
      await tester.pumpAndSettle();
      expect(ChatAppearance.instance.textSize, MessageTextSize.larger);
      expect(find.text('Larger'), findsOneWidget, reason: 'now the subtitle');
    });

    testWidgets('picking a wallpaper for all chats', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 2400);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(const ChatWallpaperPage()));
      await tester.pumpAndSettle();
      expect(find.text('For all chats'), findsOneWidget);
      expect(find.text('Same as all chats'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Waves wallpaper'));
      await tester.pumpAndSettle();
      expect(ChatAppearance.instance.wallpaper.id, 'waves');
    });

    testWidgets('picking one for a single chat, and going back', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 2400);
      addTearDown(tester.view.reset);
      await ChatAppearance.instance.setWallpaper(Wallpaper.byId('sky'));
      await tester.pumpWidget(
        app(const ChatWallpaperPage(chatId: 'c1', chatName: 'Maya')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Only for Maya'), findsOneWidget);
      expect(find.text('Same as all chats'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Rose wallpaper'));
      await tester.pumpAndSettle();
      expect(ChatAppearance.instance.wallpaperFor('c1').id, 'rose');
      expect(ChatAppearance.instance.wallpaper.id, 'sky');

      await tester.tap(find.text('Same as all chats'));
      await tester.pumpAndSettle();
      expect(ChatAppearance.instance.hasOwnWallpaper('c1'), isFalse);
    });
  });

  group('in a chat', () {
    testWidgets('messages follow the text size, and the wallpaper shows', (
      tester,
    ) async {
      await showTestChat(tester, messages: [testMessage('m1', 'hello there')]);
      double scale() => MediaQuery.textScalerOf(
        tester.element(find.text('hello there').first),
      ).scale(1);

      expect(scale(), 1.0);
      await ChatAppearance.instance.setTextSize(MessageTextSize.larger);
      await tester.pump();
      expect(scale(), 1.3);
      await ChatAppearance.instance.setTextSize(MessageTextSize.small);
      await tester.pump();
      expect(scale(), 0.9);

      final views = find.byType(WallpaperView);
      expect(views, findsOneWidget);
      expect(tester.widget<WallpaperView>(views).wallpaper.id, 'none');
      await ChatAppearance.instance.setWallpaperFor(
        'u2',
        Wallpaper.byId('grid'),
      );
      await tester.pump();
      expect(tester.widget<WallpaperView>(views).wallpaper.id, 'grid');
    });

    testWidgets('the menu has Wallpaper', (tester) async {
      await showTestChat(tester, messages: [testMessage('m1', 'hi')]);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wallpaper'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatWallpaperPage), findsOneWidget);
      expect(find.text('Same as all chats'), findsOneWidget);
    });
  });
}
