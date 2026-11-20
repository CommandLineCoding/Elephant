import 'package:flutter/material.dart';

import '../core/shared_location.dart';

/// A shared place inside a message bubble, with a button to open it in maps.
class LocationCard extends StatelessWidget {
  final SharedLocation location;
  final Color textColor;
  final VoidCallback onOpen;

  const LocationCard({
    super.key,
    required this.location,
    required this.textColor,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final muted = textColor.withValues(alpha: 0.7);
    final accuracy = location.accuracy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.place_rounded, size: 34, color: textColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Location',
                    style: TextStyle(
                      color: textColor,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    location.coordinates,
                    style: TextStyle(color: muted, fontSize: 13),
                  ),
                  if (accuracy != null && accuracy > 0)
                    Text(
                      'Within about ${accuracy.round()} m',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: onOpen,
          style: OutlinedButton.styleFrom(
            foregroundColor: textColor,
            side: BorderSide(color: textColor.withValues(alpha: 0.5)),
            visualDensity: VisualDensity.compact,
          ),
          child: const Text('Open in maps'),
        ),
      ],
    );
  }
}
