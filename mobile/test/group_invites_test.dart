import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/core/invite_links.dart';
import 'package:mobile/pages/chat/join_group_page.dart';
import 'package:mobile/services/group_invites.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/group_invite_section.dart';
import 'package:provider/provider.dart';

import 'chat_harness.dart';

final code = 'abcdefghijklmnopqrstuvwxyzABCDEF'; // 32 characters
final code2 = '0123456789_-0123456789_-01234567';

class FakeInvites implements GroupInvitesApi {
  GroupInvite invite;
  List<JoinRequest> waiting;
  InvitePreview? previewResult;
  ({JoinOutcome outcome, String groupId}) joinResult = (
    outcome: JoinOutcome.joined,
    groupId: 'g1',
  );
  Object? failPreview;
  Object? failJoin;
  final List<String> calls = [];

  FakeInvites({
    this.invite = const GroupInvite(),
    this.waiting = const [],
    this.previewResult,
  });

  @override
  Future<GroupInvite> get(String groupId) async => invite;

  @override
  Future<GroupInvite> set(
    String groupId, {
    bool? requireApproval,
    bool reset = false,
  }) async {
    calls.add('set approval=$requireApproval reset=$reset');
    invite = GroupInvite(
      code: reset || !invite.enabled ? code2 : invite.code,
      requireApproval: requireApproval ?? invite.requireApproval,
    );
    return invite;
  }

  @override
  Future<void> turnOff(String groupId) async {
    calls.add('off');
    invite = const GroupInvite();
  }

  @override
  Future<List<JoinRequest>> requests(String groupId) async => waiting;

  @override
  Future<void> decide(
    String groupId,
    String userId, {
    required bool approve,
  }) async {
    calls.add('${approve ? 'approve' : 'deny'} $userId');
    waiting = waiting.where((r) => r.userId != userId).toList();
  }

  @override
  Future<InvitePreview> preview(String c) async {
    if (failPreview != null) throw failPreview!;
    return previewResult!;
  }

  @override
  Future<({JoinOutcome outcome, String groupId})> join(String c) async {
    calls.add('join $c');
    if (failJoin != null) throw failJoin!;
    return joinResult;
  }
}

InvitePreview preview({
  bool approval = false,
  bool member = false,
  bool requested = false,
  int count = 12,
}) => InvitePreview(
  groupId: 'g1',
  name: 'Sunday Ride',
  memberCount: count,
  requireApproval: approval,
  alreadyMember: member,
  alreadyRequested: requested,
);

Widget app(Widget home) => MultiProvider(
  providers: [
    ChangeNotifierProvider(create: (_) => ThemeProvider()),
    ChangeNotifierProvider(create: (_) => GroupDetailsController()),
  ],
  child: MaterialApp(theme: AppThemes.getTheme(ThemeType.frost), home: home),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('reading a link', () {
    test('an elephant:// link and the https link both carry the code', () {
      expect(InviteLinks.codeFrom(Uri.parse('elephant://g/$code')), code);
      expect(
        InviteLinks.codeFrom(
          Uri.parse('https://elephant.commandlinecoding.in/g/$code'),
        ),
        code,
      );
      expect(InviteLinks.codeFrom(Uri.parse('elephant://g/$code2')), code2);
    });

    test('anything else is not an invite link', () {
      for (final bad in [
        'elephant://g/short',
        'elephant://g/${'a' * 33}',
        'elephant://g/${'!' * 32}',
        'elephant://g',
        'elephant://u/$code',
        'https://elephant.commandlinecoding.in/u/$code',
        'https://evil.example/g/$code',
        'https://elephant.commandlinecoding.in/g/$code/extra',
        'http://elephant.commandlinecoding.in/g/$code',
      ]) {
        expect(InviteLinks.codeFrom(Uri.parse(bad)), isNull, reason: bad);
      }
    });

    test('opening one waits for the home screen', () {
      final links = InviteLinks.instance;
      expect(links.open(Uri.parse('elephant://g/$code')), isTrue);
      expect(links.pending.value, code);
      links.pending.value = null;
      expect(links.open(Uri.parse('elephant://u/alex.1234')), isFalse);
      expect(links.pending.value, isNull);
    });

    test('a code is exactly 32 URL-safe characters', () {
      expect(InviteLinks.isCode(code), isTrue);
      expect(InviteLinks.isCode('$code '), isFalse);
      expect(InviteLinks.isCode(''), isFalse);
    });
  });

  test('the server\'s answers are read carefully', () {
    final on = GroupInvite.fromJson({
      'enabled': true,
      'code': code,
      'require_approval': true,
    });
    expect(on.enabled, isTrue);
    expect(on.requireApproval, isTrue);
    expect(GroupInvite.fromJson({'enabled': false}).enabled, isFalse);
    expect(GroupInvite.fromJson({'enabled': true}).enabled, isFalse);
    final p = InvitePreview.fromJson({
      'group_id': 'g1',
      'name': 'Trek',
      'member_count': 3,
      'already_member': true,
    });
    expect(
      (p.name, p.memberCount, p.alreadyMember, p.requireApproval),
      ('Trek', 3, true, false),
    );
    expect(
      JoinRequest.fromJson({'user_id': 'u', 'username': 'a.1234'}).title,
      'a.1234',
    );
    expect(
      JoinRequest.fromJson({
        'user_id': 'u',
        'username': 'a.1234',
        'display_name': 'Ana',
      }).title,
      'Ana',
    );
  });

  group('the invitation screen', () {
    Future<List<String>> open(WidgetTester tester, FakeInvites api) async {
      final opened = <String>[];
      await tester.pumpWidget(
        app(
          JoinGroupPage(
            key: UniqueKey(),
            code: code,
            api: api,
            openGroup: (context, p, id) => opened.add('${p.name}:$id'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return opened;
    }

    testWidgets('shows the group and how many are in it, and nobody\'s name', (
      tester,
    ) async {
      await open(tester, FakeInvites(previewResult: preview()));
      expect(find.text('Sunday Ride'), findsOneWidget);
      expect(find.text('12 members'), findsOneWidget);
      expect(find.text('Join group'), findsOneWidget);
    });

    testWidgets('says "1 member" for one', (tester) async {
      await open(tester, FakeInvites(previewResult: preview(count: 1)));
      expect(find.text('1 member'), findsOneWidget);
    });

    testWidgets('joining opens the group', (tester) async {
      final api = FakeInvites(previewResult: preview());
      final opened = await open(tester, api);
      await tester.tap(find.text('Join group'));
      await tester.pumpAndSettle();
      expect(api.calls, ['join $code']);
      expect(opened, ['Sunday Ride:g1']);
    });

    testWidgets('a group that wants approval says so, and joining only asks', (
      tester,
    ) async {
      final api = FakeInvites(previewResult: preview(approval: true))
        ..joinResult = (outcome: JoinOutcome.requested, groupId: 'g1');
      final opened = await open(tester, api);
      expect(find.text('An admin has to let you in.'), findsOneWidget);
      await tester.tap(find.text('Request to join'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty, reason: 'not in the group yet');
      expect(find.textContaining('Your request was sent'), findsOneWidget);
      expect(find.text('Request to join'), findsNothing);
    });

    testWidgets(
      'someone who already asked sees that, and a member can open it',
      (tester) async {
        await open(
          tester,
          FakeInvites(previewResult: preview(approval: true, requested: true)),
        );
        expect(find.textContaining('Your request was sent'), findsOneWidget);

        final opened = await open(
          tester,
          FakeInvites(previewResult: preview(member: true)),
        );
        await tester.tap(find.text('Open group'));
        await tester.pumpAndSettle();
        expect(opened, ['Sunday Ride:g1']);
      },
    );

    testWidgets('a link that no longer works says so and can be tried again', (
      tester,
    ) async {
      final api = FakeInvites(previewResult: preview())
        ..failPreview = Exception('offline');
      await open(tester, api);
      expect(find.text('This link doesn\'t work'), findsOneWidget);
      api.failPreview = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Sunday Ride'), findsOneWidget);
    });

    testWidgets('a failed join says why and stays', (tester) async {
      final api = FakeInvites(previewResult: preview())
        ..failJoin = Exception('offline');
      final opened = await open(tester, api);
      await tester.tap(find.text('Join group'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(find.textContaining('Couldn\'t join'), findsOneWidget);
      expect(find.text('Join group'), findsOneWidget);
    });
  });

  group('the admin\'s invite section', () {
    Future<List<String>> show(WidgetTester tester, FakeInvites api) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 3000);
      addTearDown(tester.view.reset);
      final shared = <String>[];
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SingleChildScrollView(
              child: GroupInviteSection(
                groupId: 'g1',
                api: api,
                share: (text) async => shared.add(text),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return shared;
    }

    testWidgets('starts with a way to make the link', (tester) async {
      final api = FakeInvites();
      await show(tester, api);
      expect(find.text('Create invite link'), findsOneWidget);
      expect(find.text('Share link'), findsNothing);
      await tester.tap(find.text('Create invite link'));
      await tester.pumpAndSettle();
      expect(api.calls, ['set approval=null reset=false']);
      expect(find.textContaining(code2), findsOneWidget);
      expect(find.text('Share link'), findsOneWidget);
    });

    testWidgets('shows the link, copies it and shares it', (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final shared = await show(
        tester,
        FakeInvites(invite: GroupInvite(code: code)),
      );
      final linkText = find.textContaining(code);
      expect(linkText, findsOneWidget);
      final link = tester.widget<Text>(linkText).data!;
      expect(link, endsWith('/g/$code'));

      await tester.tap(linkText);
      await tester.pump();
      expect(copied, link);

      await tester.tap(find.text('Share link'));
      await tester.pump();
      expect(shared.single, contains(link));
    });

    testWidgets('approval can be turned on', (tester) async {
      final api = FakeInvites(invite: GroupInvite(code: code));
      await show(tester, api);
      final tile = find.ancestor(
        of: find.text('Admins approve new members'),
        matching: find.byType(InkWell),
      );
      await tester.tap(
        find.descendant(of: tile.first, matching: find.byType(Switch)),
      );
      await tester.pumpAndSettle();
      expect(api.calls, ['set approval=true reset=false']);
      expect(api.invite.requireApproval, isTrue);
    });

    testWidgets('resetting and turning off ask first', (tester) async {
      final api = FakeInvites(invite: GroupInvite(code: code));
      await show(tester, api);

      await tester.tap(find.text('Reset link'));
      await tester.pumpAndSettle();
      expect(find.text('Reset the link?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.calls, isEmpty);

      await tester.tap(find.text('Reset link'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
      await tester.pumpAndSettle();
      expect(api.calls, ['set approval=null reset=true']);
      expect(
        find.textContaining(code2),
        findsOneWidget,
        reason: 'the new code shows',
      );

      await tester.tap(find.text('Turn off link'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Turn off'));
      await tester.pumpAndSettle();
      expect(api.calls.last, 'off');
      expect(find.text('Create invite link'), findsOneWidget);
    });

    testWidgets('lists who is waiting, and lets them in or turns them down', (
      tester,
    ) async {
      final api = FakeInvites(
        invite: GroupInvite(code: code, requireApproval: true),
        waiting: const [
          JoinRequest(userId: 'u2', username: 'bob.1234', displayName: 'Bob'),
          JoinRequest(userId: 'u3', username: 'cy.5678', displayName: ''),
        ],
      );
      await show(tester, api);
      expect(find.text('Waiting to join (2)'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(
        find.text('cy.5678'),
        findsOneWidget,
        reason: 'no display name: the username',
      );

      await tester.tap(find.byTooltip('Let Bob in'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Turn cy.5678 down'));
      await tester.pumpAndSettle();
      expect(api.calls, ['approve u2', 'deny u3']);
      expect(find.textContaining('Waiting to join'), findsNothing);
    });

    testWidgets('without approval, no waiting list is asked for', (
      tester,
    ) async {
      final api = FakeInvites(
        invite: GroupInvite(code: code),
        waiting: const [
          JoinRequest(userId: 'u2', username: 'bob.1234', displayName: 'Bob'),
        ],
      );
      await show(tester, api);
      expect(find.textContaining('Waiting to join'), findsNothing);
    });
  });
}
