import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/group.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/widgets/admins_only_banner.dart';
import 'package:mobile/widgets/chat_page_widgets.dart';

import 'chat_harness.dart';

Group aGroup({String description = '', bool adminsOnly = false}) => Group(
  id: 'g1',
  name: 'The group',
  createdBy: 'u2',
  createdAt: DateTime(2026, 11, 21),
  description: description,
  adminsOnly: adminsOnly,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('reading a group', () {
    test('has a description and a posting rule', () {
      final g = Group.fromJson({
        'id': 'g1',
        'name': 'Sunday Ride',
        'created_by': 'u2',
        'created_at': '2026-11-21T10:00:00Z',
        'description': 'Weekend rides',
        'admins_only': true,
      });
      expect(g.description, 'Weekend rides');
      expect(g.adminsOnly, isTrue);
    });

    test('from an older server has neither', () {
      final g = Group.fromJson({'id': 'g1', 'name': 'Old group'});
      expect(g.description, '');
      expect(g.adminsOnly, isFalse);
    });
  });

  group('the message box', () {
    final me = testMember('me', 'Me');
    final myAdmin = testMember('me', 'Me', admin: true);
    final bob = testMember('u2', 'Bob', admin: true);

    Future<void> open(
      WidgetTester tester, {
      required Group info,
      required bool iAmAdmin,
    }) async {
      await showTestChat(
        tester,
        chatId: 'g1',
        isGroup: true,
        messages: [testMessage('m1', 'hello')],
        members: [iAmAdmin ? myAdmin : me, bob],
        groupInfo: info,
        auth: TestAuth('me'),
      );
    }

    testWidgets('is there in an ordinary group', (tester) async {
      await open(tester, info: aGroup(), iAmAdmin: false);
      expect(find.byType(ChatComposer), findsOneWidget);
      expect(find.byType(AdminsOnlyBanner), findsNothing);
    });

    testWidgets('gives way to a note for a member of an admins-only group', (
      tester,
    ) async {
      await open(tester, info: aGroup(adminsOnly: true), iAmAdmin: false);
      expect(find.byType(ChatComposer), findsNothing);
      expect(find.text('Only admins can send messages'), findsOneWidget);
    });

    testWidgets('stays for an admin of an admins-only group', (tester) async {
      await open(tester, info: aGroup(adminsOnly: true), iAmAdmin: true);
      expect(find.byType(ChatComposer), findsOneWidget);
      expect(find.byType(AdminsOnlyBanner), findsNothing);
    });

    testWidgets('is not touched in a direct chat', (tester) async {
      await showTestChat(tester, messages: [testMessage('m1', 'hello')]);
      expect(find.byType(ChatComposer), findsOneWidget);
    });
  });

  group('the group_updated event', () {
    test('tells the app which group to look at again', () async {
      final updated = <String>[];
      final handler = ChatEventHandler(
        inboxController: InboxController(),
        activeChatController: TestChat(),
        currentUserIdProvider: () => 'me',
        onGroupUpdated: updated.add,
      );
      await handler.handleIncomingEvent({
        'type': 'group_updated',
        'group_id': 'G1',
      });
      expect(updated, ['g1'], reason: 'ids are lowercased');
      await handler.handleIncomingEvent({'type': 'group_updated'});
      expect(
        updated,
        hasLength(1),
        reason: 'an event with no group does nothing',
      );
    });
  });
}
