import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/links.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/chat_page_widgets.dart';

void main() {
  group('linksIn', () {
    test('finds bare and Markdown links, without trailing punctuation', () {
      expect(
        linksIn('See https://a.example/x, and [docs](https://b.example/d).'),
        ['https://b.example/d', 'https://a.example/x'],
      );
    });
    test('lists a repeated link once', () {
      expect(linksIn('https://a.example and https://a.example!'), [
        'https://a.example',
      ]);
    });
    test('plain text has none', () {
      expect(linksIn('no links here, just a.b'), isEmpty);
    });
  });

  test('only web and mail links can be opened', () {
    expect(isOpenableLink('https://example.com'), isTrue);
    expect(isOpenableLink('http://example.com'), isTrue);
    expect(isOpenableLink('mailto:a@b.example'), isTrue);
    expect(isOpenableLink('javascript:alert(1)'), isFalse);
    expect(isOpenableLink('intent://scan#Intent;end'), isFalse);
    expect(isOpenableLink('file:///etc/passwd'), isFalse);
  });

  Future<void> showBubble(WidgetTester tester, String content) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppThemes.getTheme(ThemeType.frost),
        home: Scaffold(
          body: ChatBubble(
            isMe: false,
            message: Message(
              id: '1',
              senderId: 'u2',
              receiverId: 'me',
              content: content,
              createdAt: DateTime.now(),
              isRead: true,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('tapping a link shows the full address before opening', (
    tester,
  ) async {
    await showBubble(tester, 'Read [the docs](https://example.com/docs)');
    await tester.tapOnText(find.textRange.ofSubstring('the docs'));
    await tester.pumpAndSettle();

    expect(find.text('Open this link?'), findsOneWidget);
    expect(find.text('https://example.com/docs'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Open this link?'), findsNothing);
  });

  testWidgets('a link that is not a web or mail link is refused', (
    tester,
  ) async {
    await showBubble(tester, 'Click [here](javascript:alert(1))');
    await tester.tapOnText(find.textRange.ofSubstring('here'));
    await tester.pump();

    expect(find.text('Open this link?'), findsNothing);
    expect(find.text("This link can't be opened"), findsOneWidget);
  });
}
