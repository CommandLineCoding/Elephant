import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/link_preview.dart';
import 'package:mobile/core/message_payload.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_harness.dart';

const page = 'https://news.example.com/story?id=7';

InternetAddress ip(String a) => InternetAddress(a);

PageResponse html(
  String body, {
  int status = 200,
  String type = 'text/html; charset=utf-8',
  String? location,
  void Function()? close,
}) => PageResponse(
  status: status,
  contentType: type,
  location: location,
  body: Stream.value(utf8.encode(body)),
  close: close,
);

const sample = '''
<!doctype html><html><head>
<title>Ignored &amp; replaced</title>
<meta property="og:title" content="Big news &amp; more">
<meta property='og:description' content='A longer   description
 over two lines.'>
<meta property="og:site_name" content="Example News">
</head><body>hi</body></html>''';

/// A fetcher whose "web" is [pages] (URL → response), and whose DNS answers
/// with a public address unless [dns] says otherwise.
LinkPreviewFetcher fetcherFor(
  Map<String, PageResponse Function()> pages, {
  Map<String, List<String>> dns = const {},
  List<Uri>? asked,
  Duration timeout = const Duration(seconds: 5),
}) => LinkPreviewFetcher(
  timeout: timeout,
  resolve: (host) async => [
    for (final a in dns[host] ?? ['93.184.216.34']) ip(a),
  ],
  get: (uri) async {
    asked?.add(uri);
    final make = pages[uri.toString()];
    if (make == null) throw const SocketException('no such page');
    return make();
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);
  tearDown(() => LinkPreviewFetcher.shared = LinkPreviewFetcher());

  group('reading a page', () {
    test('uses the Open Graph tags', () {
      final p = LinkPreview.parseHtml(page, sample)!;
      expect(p.url, page);
      expect(p.title, 'Big news & more');
      expect(p.description, 'A longer description over two lines.');
      expect(p.site, 'Example News');
      expect(p.siteLabel, 'Example News');
    });

    test('falls back to the title tag, the description tag and the host', () {
      final p = LinkPreview.parseHtml(
        page,
        '<html><head><TITLE>\n  Plain   title </TITLE>'
        '<meta name="description" content="Meta description"></head></html>',
      )!;
      expect(p.title, 'Plain title');
      expect(p.description, 'Meta description');
      expect(p.site, isNull);
      expect(p.siteLabel, 'news.example.com');
    });

    test('attribute order, quoting and case do not matter', () {
      final p = LinkPreview.parseHtml(
        page,
        '<META CONTENT="First" PROPERTY="og:title" />'
        '<meta content=Unquoted name=description>',
      )!;
      expect(p.title, 'First');
      expect(p.description, 'Unquoted');
    });

    test('decodes entities, drops tags, and clips long text', () {
      final long = 'w' * 400;
      final p = LinkPreview.parseHtml(
        page,
        '<meta property="og:title" content="<b>Bold</b> &amp; Q&#39;s &#x1F600;">'
        '<meta property="og:description" content="$long">'
        '<meta property="og:site_name" content="${'s' * 100}">',
      )!;
      expect(p.title, "Bold & Q's 😀");
      expect(p.description!.length, LinkPreview.maxDescription);
      expect(p.description, endsWith('…'));
      expect(p.site!.length, LinkPreview.maxSite);
    });

    test('a ">" inside a value does not end the tag', () {
      final p = LinkPreview.parseHtml(
        page,
        '<meta property="og:title" content="Home > News > Story">'
        "<meta name='description' content='5 > 3 and \"quoted\"'>",
      )!;
      expect(p.title, 'Home > News > Story');
      expect(p.description, '5 > 3 and "quoted"');
    });

    test('escaped markup is text, not markup', () {
      final p = LinkPreview.parseHtml(
        page,
        '<meta property="og:title" content="1 &lt; 2 &amp;&amp; &lt;b&gt;x&lt;/b&gt;">',
      )!;
      expect(p.title, '1 < 2 && <b>x</b>');
    });

    test('an unknown entity is left as it is', () {
      final p = LinkPreview.parseHtml(
        page,
        '<meta property="og:title" content="Caf&eacute; &#0; &#99999999;">',
      )!;
      expect(p.title, 'Caf&eacute; &#0; &#99999999;');
    });

    test('a page with no title has no preview', () {
      expect(
        LinkPreview.parseHtml(page, '<html><body>x</body></html>'),
        isNull,
      );
      expect(
        LinkPreview.parseHtml(page, '<meta property="og:title" content="  ">'),
        isNull,
      );
    });

    test('takes the first of repeated tags', () {
      final p = LinkPreview.parseHtml(
        page,
        '<meta property="og:title" content="One"><meta property="og:title" content="Two">',
      )!;
      expect(p.title, 'One');
    });
  });

  group('which addresses are public', () {
    test('private, local and reserved ranges are not', () {
      for (final a in [
        '127.0.0.1',
        '10.0.0.5',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.1.1',
        '169.254.169.254',
        '100.64.0.1',
        '100.127.255.255',
        '0.0.0.0',
        '224.0.0.1',
        '255.255.255.255',
        '::1',
        '::',
        'fe80::1',
        'fc00::1',
        'fd12:3456::1',
        'ff02::1',
        '::ffff:10.0.0.1',
        '::ffff:192.168.0.9',
        '::ffff:127.0.0.1',
      ]) {
        expect(isPublicAddress(ip(a)), isFalse, reason: a);
      }
    });

    test('public ones are', () {
      for (final a in [
        '93.184.216.34',
        '8.8.8.8',
        '172.15.0.1',
        '172.32.0.1',
        '100.63.255.255',
        '100.128.0.1',
        '2606:4700:4700::1111',
        '::ffff:8.8.8.8',
      ]) {
        expect(isPublicAddress(ip(a)), isTrue, reason: a);
      }
    });
  });

  group('which links are fetched', () {
    bool ok(String url) => isFetchableUri(Uri.parse(url));

    test('https links to real hosts', () {
      expect(ok('https://example.com'), isTrue);
      expect(ok('https://news.example.com/a?b=c#d'), isTrue);
      expect(ok('https://example.com:443/x'), isTrue);
      expect(ok('https://93.184.216.34/x'), isTrue);
      expect(ok('https://[2606:4700:4700::1111]/'), isTrue);
    });

    test('nothing else', () {
      for (final url in [
        'http://example.com',
        'ftp://example.com',
        'https://user:pw@example.com',
        'https://user@example.com',
        'https://example.com:8443',
        'https://localhost',
        'https://LOCALHOST/x',
        'https://app.localhost',
        'https://printer.local',
        'https://box.internal',
        'https://router.lan',
        'https://intranet',
        'https://127.0.0.1',
        'https://192.168.0.1/admin',
        'https://169.254.169.254/latest/meta-data',
        'https://[::1]/',
        'https://[fe80::1]/',
        'https://[::ffff:10.0.0.1]/',
      ]) {
        expect(ok(url), isFalse, reason: url);
      }
    });
  });

  group('fetching a preview', () {
    test('reads a page, and keeps the link it was asked for', () async {
      final asked = <Uri>[];
      final p = await fetcherFor({
        page: () => html(sample),
      }, asked: asked).fetch(page);
      expect(p!.title, 'Big news & more');
      expect(p.url, page);
      expect(asked.single.toString(), page);
    });

    test(
      'follows redirects, but the preview keeps the original link',
      () async {
        final p = await fetcherFor({
          page: () =>
              html('', status: 301, location: 'https://example.com/new'),
          'https://example.com/new': () =>
              html('', status: 302, location: '/newer'),
          'https://example.com/newer': () => html(sample),
        }).fetch(page);
        expect(p!.url, page);
        expect(p.title, 'Big news & more');
      },
    );

    test('never follows a redirect somewhere unsafe', () async {
      for (final target in [
        'http://example.com/plain',
        'https://127.0.0.1/',
        'https://192.168.0.1/admin',
        'https://localhost/x',
        'https://intranet/x',
        'https://evil.example.org:9000/x',
      ]) {
        final asked = <Uri>[];
        final p = await fetcherFor({
          page: () => html('', status: 302, location: target),
          target: () => html(sample),
        }, asked: asked).fetch(page);
        expect(p, isNull, reason: target);
        expect(asked.map((u) => u.toString()), [page], reason: target);
      }
    });

    test('refuses a host that resolves to a private address', () async {
      final asked = <Uri>[];
      final p = await fetcherFor(
        {page: () => html(sample)},
        dns: {
          'news.example.com': ['10.1.2.3'],
        },
        asked: asked,
      ).fetch(page);
      expect(p, isNull);
      expect(asked, isEmpty, reason: 'never even connected');
    });

    test('one private answer among public ones is enough to refuse', () async {
      final p = await fetcherFor(
        {page: () => html(sample)},
        dns: {
          'news.example.com': ['93.184.216.34', '192.168.1.5'],
        },
      ).fetch(page);
      expect(p, isNull);
    });

    test('checks the address again after a redirect', () async {
      final p = await fetcherFor(
        {
          page: () =>
              html('', status: 302, location: 'https://sneaky.example.org/'),
          'https://sneaky.example.org/': () => html(sample),
        },
        dns: {
          'sneaky.example.org': ['127.0.0.1'],
        },
      ).fetch(page);
      expect(p, isNull);
    });

    test('stops after three redirects', () async {
      var hops = 0;
      final p = await fetcherFor({
        for (var i = 0; i < 10; i++)
          i == 0 ? page : 'https://example.com/$i': () {
            hops++;
            return html(
              '',
              status: 302,
              location: 'https://example.com/${i + 1}',
            );
          },
      }).fetch(page);
      expect(p, isNull);
      expect(hops, 4, reason: 'the page and three redirects');
    });

    test('only reads pages that are HTML and fine', () async {
      expect(
        await fetcherFor({
          page: () => html(sample, type: 'application/pdf'),
        }).fetch(page),
        isNull,
      );
      expect(
        await fetcherFor({
          page: () => html(sample, type: 'application/json'),
        }).fetch(page),
        isNull,
      );
      expect(
        await fetcherFor({page: () => html(sample, status: 404)}).fetch(page),
        isNull,
      );
      expect(
        await fetcherFor({page: () => html(sample, status: 500)}).fetch(page),
        isNull,
      );
      final xhtml = await fetcherFor({
        page: () => html(sample, type: 'application/xhtml+xml'),
      }).fetch(page);
      expect(xhtml, isNotNull);
    });

    test('reads only the start of a big page', () async {
      var tail = false;
      final p = await fetcherFor({
        page: () => PageResponse(
          status: 200,
          contentType: 'text/html',
          body:
              Stream.fromIterable([
                utf8.encode('<meta property="og:title" content="Early">'),
                ...List.generate(40, (_) => utf8.encode('y' * 4096)),
                utf8.encode('<meta property="og:description" content="Late">'),
              ]).map((c) {
                if (String.fromCharCodes(c).contains('Late')) tail = true;
                return c;
              }),
        ),
      }).fetch(page);
      expect(p!.title, 'Early');
      expect(p.description, isNull, reason: 'past the first 64 KB');
      expect(tail, isFalse, reason: 'it stopped reading');
    });

    test('tolerates bad bytes in a page', () async {
      final p = await fetcherFor({
        page: () => PageResponse(
          status: 200,
          contentType: 'text/html',
          body: Stream.value([
            ...utf8.encode('<title>Caf'),
            0xff,
            0xfe,
            ...utf8.encode('</title>'),
          ]),
        ),
      }).fetch(page);
      expect(p!.title, startsWith('Caf'));
    });

    test('closes the response whatever happens', () async {
      var closed = 0;
      void close() => closed++;
      await fetcherFor({page: () => html(sample, close: close)}).fetch(page);
      await fetcherFor({
        page: () => html(sample, status: 404, close: close),
      }).fetch(page);
      await fetcherFor({
        page: () => html(
          '',
          status: 302,
          location: 'https://example.com/n',
          close: close,
        ),
        'https://example.com/n': () => html(sample, close: close),
      }).fetch(page);
      expect(closed, 4);
    });

    test('gives up on a slow page', () async {
      final p = await LinkPreviewFetcher(
        timeout: const Duration(milliseconds: 50),
        resolve: (_) async => [ip('93.184.216.34')],
        get: (_) => Completer<PageResponse>().future,
      ).fetch(page);
      expect(p, isNull);
    });

    test('network errors are just no preview', () async {
      expect(await fetcherFor({}).fetch(page), isNull);
      expect(
        await LinkPreviewFetcher(
          resolve: (_) async => throw const SocketException('no dns'),
          get: (_) async => html(sample),
        ).fetch(page),
        isNull,
      );
      expect(await fetcherFor({}).fetch('not a link'), isNull);
      expect(await fetcherFor({}).fetch(''), isNull);
    });
  });

  group('a preview that arrives', () {
    LinkPreview? read(Map<String, dynamic> data, String text) =>
        LinkPreview.fromPayload(
          MessagePayload('preview', data),
          messageText: text,
        );
    Map<String, dynamic> good() => {'url': page, 'title': 'Big news'};

    test('is shown when its link is in the text', () {
      expect(read(good(), 'look $page now'), isNotNull);
      expect(read(good(), '[a story]($page)'), isNotNull);
      final p = read(
        good()
          ..['desc'] = 'd' * 500
          ..['site'] = 'Site',
        'see $page',
      )!;
      expect(p.description!.length, LinkPreview.maxDescription);
      expect(p.site, 'Site');
    });

    test('is not shown for a link that is not in the text', () {
      expect(read(good(), 'nothing here'), isNull);
      expect(read(good(), 'see https://other.example.com'), isNull);
      expect(read(good(), ''), isNull);
    });

    test('is not shown if it is malformed', () {
      expect(read(good()..['title'] = '', 'x $page'), isNull);
      expect(read(good()..remove('title'), 'x $page'), isNull);
      expect(read(good()..['title'] = 5, 'x $page'), isNull);
      expect(read(good()..['url'] = 5, 'x $page'), isNull);
      expect(read({'title': 'x'}, 'x $page'), isNull);
      expect(read(good()..['title'] = 't' * 300, 'x $page'), isNull);
      const http = 'http://example.com/a';
      expect(read({'url': http, 'title': 't'}, 'x $http'), isNull);
      const login = 'https://me:pw@example.com/a';
      expect(read({'url': login, 'title': 't'}, 'x $login'), isNull);
      final long = 'https://example.com/${'a' * 600}';
      expect(read({'url': long, 'title': 't'}, 'x $long'), isNull);
      expect(
        LinkPreview.fromPayload(
          MessagePayload('poll', good()),
          messageText: 'x $page',
        ),
        isNull,
      );
      expect(LinkPreview.fromPayload(null, messageText: 'x $page'), isNull);
    });
  });

  group('with the app', () {
    LinkPreviewFetcher serving(
      Map<String, PageResponse Function()> pages, {
      List<Uri>? asked,
    }) => fetcherFor(pages, asked: asked);

    Future<TestChat> compose(WidgetTester tester) =>
        showTestChat(tester, messages: []);

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField).last, text);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
    }

    testWidgets('a pasted link gets a preview above the message box', (
      tester,
    ) async {
      final asked = <Uri>[];
      LinkPreviewFetcher.shared = serving({
        page: () => html(sample),
      }, asked: asked);
      await compose(tester);
      await type(tester, 'have you seen $page');

      expect(find.text('Example News'), findsOneWidget);
      expect(find.text('Big news & more'), findsOneWidget);
      expect(asked.single.toString(), page);
    });

    testWidgets('typing a link is not looked up until you pause', (
      tester,
    ) async {
      final asked = <Uri>[];
      LinkPreviewFetcher.shared = serving({
        page: () => html(sample),
      }, asked: asked);
      await compose(tester);
      await tester.enterText(
        find.byType(TextField).last,
        'see https://news.exam',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).last, 'see $page');
      await tester.pump(const Duration(milliseconds: 300));
      expect(asked, isEmpty, reason: 'still typing');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(asked.length, 1);
    });

    testWidgets('sending with a preview puts it inside the message', (
      tester,
    ) async {
      LinkPreviewFetcher.shared = serving({page: () => html(sample)});
      final chat = await compose(tester);
      await type(tester, 'have you seen $page');
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();

      final sent = chat.sent.single;
      expect(sent.silent, isFalse);
      expect(MessagePayload.readable(sent.text), 'have you seen $page');
      final p = LinkPreview.fromPayload(
        MessagePayload.split(sent.text).payload,
        messageText: MessagePayload.readable(sent.text),
      )!;
      expect(p.title, 'Big news & more');
      expect(p.url, page);
      // It goes, and the box is clear.
      expect(find.text('Big news & more'), findsOneWidget);
    });

    testWidgets('the close button sends it without a preview', (tester) async {
      final asked = <Uri>[];
      LinkPreviewFetcher.shared = serving({
        page: () => html(sample),
      }, asked: asked);
      final chat = await compose(tester);
      await type(tester, 'have you seen $page');
      await tester.tap(find.byTooltip('Send without a preview'));
      await tester.pump();
      expect(find.text('Big news & more'), findsNothing);

      // Typing more doesn't bring it back.
      await type(tester, 'have you seen $page really');
      expect(find.text('Big news & more'), findsNothing);
      expect(asked.length, 1);

      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();
      expect(chat.sent.single.text, 'have you seen $page really');
    });

    testWidgets('removing the link removes the preview', (tester) async {
      LinkPreviewFetcher.shared = serving({page: () => html(sample)});
      final chat = await compose(tester);
      await type(tester, 'have you seen $page');
      expect(find.text('Big news & more'), findsOneWidget);

      await type(tester, 'never mind');
      expect(find.text('Big news & more'), findsNothing);
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();
      expect(chat.sent.single.text, 'never mind');
    });

    testWidgets('a preview for another link is not sent', (tester) async {
      LinkPreviewFetcher.shared = serving({
        page: () => html(sample),
        'https://other.example.com/': () => html('<title>Other</title>'),
      });
      final chat = await compose(tester);
      await type(tester, 'see $page');
      expect(find.text('Big news & more'), findsOneWidget);

      // Swap the link and send before the new preview is ready.
      await tester.enterText(
        find.byType(TextField).last,
        'see https://other.example.com/',
      );
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();
      expect(chat.sent.single.text, 'see https://other.example.com/');
    });

    testWidgets('with previews switched off nothing is looked up', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'link_previews': false});
      final asked = <Uri>[];
      LinkPreviewFetcher.shared = serving({
        page: () => html(sample),
      }, asked: asked);
      final chat = await compose(tester);
      await type(tester, 'see $page');
      expect(asked, isEmpty);
      expect(find.text('Big news & more'), findsNothing);
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();
      expect(chat.sent.single.text, 'see $page');
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets('a link that has no preview is sent as it is', (tester) async {
      LinkPreviewFetcher.shared = serving({
        page: () => html(sample, status: 404),
      });
      final chat = await compose(tester);
      await type(tester, 'see $page');
      expect(find.byTooltip('Send without a preview'), findsNothing);
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();
      expect(chat.sent.single.text, 'see $page');
    });

    testWidgets('http links and private addresses are never looked up', (
      tester,
    ) async {
      final asked = <Uri>[];
      LinkPreviewFetcher.shared = serving({}, asked: asked);
      await compose(tester);
      await type(tester, 'a http://example.com/x b https://192.168.0.1/admin');
      expect(asked, isEmpty);
    });

    testWidgets('a preview that arrives is a card, and the link asks first', (
      tester,
    ) async {
      final content = MessagePayload.encode(
        'preview',
        const LinkPreview(
          url: page,
          title: 'Big news',
          description: 'All about it',
          site: 'Example News',
        ).toData(),
        text: 'read this: $page',
      );
      await showTestChat(tester, messages: [testMessage('m1', content)]);
      expect(find.text('Big news'), findsOneWidget);
      expect(find.text('All about it'), findsOneWidget);
      expect(find.text('Example News'), findsOneWidget);

      await tester.tap(find.text('Big news'));
      await tester.pumpAndSettle();
      expect(find.text('Open this link?'), findsOneWidget);
      expect(find.text(page), findsWidgets);
    });

    testWidgets('a preview that does not match its text is not drawn', (
      tester,
    ) async {
      final content = MessagePayload.encode(
        'preview',
        const LinkPreview(
          url: 'https://bank.example.com/login',
          title: 'Your bank',
        ).toData(),
        text: 'read this: $page',
      );
      await showTestChat(tester, messages: [testMessage('m1', content)]);
      expect(find.text('Your bank'), findsNothing);
      expect(find.textContaining('read this'), findsOneWidget);
    });
  });

  group('sending', () {
    test(
      'a preview that would make the message too long is left out',
      () async {
        final chat = TestChat()
          ..currentUserIdProvider = (() => 'me')
          ..currentChatUserId = 'u2';
        final text = '${'x' * 2300} $page';
        await chat.sendTextMessage(
          text,
          preview: const LinkPreview(
            url: page,
            title: 'Title',
            description: 'Description',
          ),
        );
        expect(
          chat.sent.single.text,
          text,
          reason: 'sent as it is, not refused',
        );
      },
    );

    test('a preview that fits goes along', () async {
      final chat = TestChat()
        ..currentUserIdProvider = (() => 'me')
        ..currentChatUserId = 'u2';
      await chat.sendTextMessage(
        'see $page',
        preview: const LinkPreview(url: page, title: 'Title'),
      );
      expect(
        MessagePayload.split(chat.sent.single.text).payload!.kind,
        'preview',
      );
    });
  });
}
