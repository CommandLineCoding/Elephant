import 'package:flutter/material.dart';
import 'package:mobile/pages/chat/block_user.dart';
import 'package:mobile/services/blocked_users.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/surfaces.dart';

/// The people you blocked, each with Unblock.
class BlockedUsersPage extends StatefulWidget {
  const BlockedUsersPage({super.key});

  @override
  State<BlockedUsersPage> createState() => _BlockedUsersPageState();
}

class _BlockedUsersPageState extends State<BlockedUsersPage> {
  @override
  void initState() {
    super.initState();
    BlockedUsers.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const ElephantAppBar(title: Text('Blocked users')),
      body: ScreenBackground(
        child: ListenableBuilder(
          listenable: BlockedUsers.instance,
          builder: (context, _) {
            final users = BlockedUsers.instance.users;
            if (users.isEmpty) {
              return const EmptyState(
                icon: Icons.block_rounded,
                title: 'No one is blocked',
                message:
                    'People you block can\'t send you direct messages. Block '
                    'someone from their chat or contact info.',
              );
            }
            return ListView(
              padding: const EdgeInsets.only(top: Insets.lg),
              children: [
                Section(
                  children: [
                    for (final user in users)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          Insets.lg,
                          Insets.sm,
                          Insets.sm,
                          Insets.sm,
                        ),
                        child: Row(
                          children: [
                            ElephantAvatar(
                              name: user.displayName,
                              seed: user.id,
                              size: 40,
                            ),
                            const SizedBox(width: Insets.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    user.displayName,
                                    style: context.text.bodyLarge,
                                  ),
                                  Text(
                                    '@${user.username}',
                                    style: context.text.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  unblock(context, user.id, user.displayName),
                              child: const Text('Unblock'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
