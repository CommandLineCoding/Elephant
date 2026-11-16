import 'package:flutter/material.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:url_launcher/url_launcher.dart';

final _bareLink = RegExp(r'https?://[^\s<>]+');
final _markdownLink = RegExp(r'\]\((\S+?)\)');
// Trailing punctuation usually ends the sentence, not the link.
final _trailing = RegExp(r'[.,;:!?)\]]+$');

/// The links in a message, bare or written as `[text](url)`, in order and
/// without duplicates.
List<String> linksIn(String text) {
  final found = <String>[];
  void add(String link) {
    final clean = link.replaceFirst(_trailing, '');
    if (clean.isNotEmpty && !found.contains(clean)) found.add(clean);
  }

  for (final m in _markdownLink.allMatches(text)) {
    add(m[1]!);
  }
  for (final m in _bareLink.allMatches(text)) {
    add(m[0]!);
  }
  return found;
}

/// Only web and mail links are opened. Anything else (`javascript:`,
/// `intent:`, `file:`...) is refused.
bool isOpenableLink(String href) {
  final uri = Uri.tryParse(href);
  return uri != null &&
      const {'http', 'https', 'mailto'}.contains(uri.scheme.toLowerCase());
}

/// Shows the full address and opens it in the browser only if the user
/// agrees, so link text can't disguise where a link goes.
Future<void> confirmAndOpenLink(BuildContext context, String href) async {
  if (!isOpenableLink(href)) {
    showSnack(context, "This link can't be opened", isError: true);
    return;
  }
  final open = await confirmAction(
    context,
    title: 'Open this link?',
    message: href,
    confirmLabel: 'Open',
  );
  if (!open) return;
  final launched = await launchUrl(
    Uri.parse(href),
    mode: LaunchMode.externalApplication,
  );
  if (!launched && context.mounted) {
    showSnack(context, "Couldn't open the link", isError: true);
  }
}
