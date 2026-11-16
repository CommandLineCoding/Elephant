import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:mobile/core/chat_markdown.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/chat_page_widgets.dart';

String render(String message) => md
    .markdownToHtml(
      prepareChatMarkdown(message),
      extensionSet: chatMarkdownExtensions,
    )
    .trim();

void main() {
  group('plain text stays plain', () {
    const plain = {
      'my_file_name and other_file_name':
          '<p>my_file_name and other_file_name</p>',
      '2*3*4 = 24': '<p>2*3*4 = 24</p>',
      '5*3 and 2*4': '<p>5*3 and 2*4</p>',
      '_not closed': '<p>_not closed</p>',
      '__init__.py': '<p>__init__.py</p>',
      '# not a heading, just a tag': '<p># not a heading, just a tag</p>',
      '---': '<p>---</p>',
      'hello\n===': '<p>hello\n===</p>',
      'a | b\n--|--\n1 | 2': '<p>a | b\n--|--\n1 | 2</p>',
      '<b>html</b>': '<p>&lt;b&gt;html&lt;/b&gt;</p>',
    };
    plain.forEach((input, html) {
      test(input.replaceAll('\n', r'\n'), () => expect(render(input), html));
    });
  });

  group('intended formatting still works', () {
    const formatted = {
      '**bold** and _italic_ and `code`':
          '<p><strong>bold</strong> and <em>italic</em> and <code>code</code></p>',
      '*one* star': '<p><em>one</em> star</p>',
      '~~strike~~': '<p><del>strike</del></p>',
      '[link](https://x.y)': '<p><a href="https://x.y">link</a></p>',
      'see https://example.com/a_b*c*d':
          '<p>see <a href="https://example.com/a_b*c*d">https://example.com/a_b*c*d</a></p>',
      '1. first\n2. second': '<ol>\n<li>first</li>\n<li>second</li>\n</ol>',
      '- dash item': '<ul>\n<li>dash item</li>\n</ul>',
    };
    formatted.forEach((input, html) {
      test(input.replaceAll('\n', r'\n'), () => expect(render(input), html));
    });
  });

  test('code is left exactly as typed', () {
    expect(
      render('run `2*3*4` and `__init__`'),
      '<p>run <code>2*3*4</code> and <code>__init__</code></p>',
    );
    expect(
      render('```\n# not a heading\na*b*c\n```'),
      '<pre><code># not a heading\na*b*c\n</code></pre>',
    );
  });

  testWidgets('a chat bubble shows plain text as typed', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemes.getTheme(ThemeType.frost),
        home: Scaffold(
          body: ChatBubble(
            isMe: false,
            message: Message(
              id: '1',
              senderId: 'u2',
              receiverId: 'me',
              content: '2*3*4 = 24 and __init__.py',
              createdAt: DateTime.now(),
              isRead: true,
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('2*3*4 = 24 and __init__.py'), findsOneWidget);
  });
}
