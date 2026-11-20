import 'package:flutter/material.dart';

import '../core/shared_contact.dart';
import 'ui/avatar.dart';

/// A shared contact inside a message bubble, with a button to message them
/// (null [onMessage] hides it, e.g. when the contact is you).
class ContactCard extends StatelessWidget {
  final SharedContact contact;
  final Color textColor;
  final VoidCallback? onMessage;

  const ContactCard({
    super.key,
    required this.contact,
    required this.textColor,
    this.onMessage,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            ElephantAvatar(name: contact.name, seed: contact.id, size: 40),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '@${contact.username}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (onMessage != null) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: onMessage,
            style: OutlinedButton.styleFrom(
              foregroundColor: textColor,
              side: BorderSide(color: textColor.withValues(alpha: 0.5)),
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('Message'),
          ),
        ],
      ],
    );
  }
}
