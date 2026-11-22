import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/status_content.dart';
import 'package:mobile/services/blocked_users.dart';
import 'package:mobile/services/statuses.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:provider/provider.dart';

/// Write a text status: words on a coloured background, in one of a few fonts.
/// It goes to the people the person chats with, and goes after 24 hours.
class StatusComposerPage extends StatefulWidget {
  /// Replaced in tests.
  final Statuses? statuses;

  const StatusComposerPage({super.key, this.statuses});

  @override
  State<StatusComposerPage> createState() => _StatusComposerPageState();
}

class _StatusComposerPageState extends State<StatusComposerPage> {
  final _text = TextEditingController();
  int _background = 0;
  int _font = 0;
  bool _posting = false;

  Statuses get _statuses => widget.statuses ?? Statuses.instance;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  List<String> _recipients() {
    final chats = context.read<InboxController>().inbox;
    return statusRecipients(
      chats,
      blocked: {
        for (final c in chats)
          if (BlockedUsers.instance.isBlocked(c.id)) c.id.toLowerCase(),
      },
    );
  }

  Future<void> _post() async {
    final myId = context.read<AuthState>().currentUser?.id;
    if (myId == null || _posting) return;
    setState(() => _posting = true);
    final result = await _statuses.post(
      myId: myId,
      text: _text.text,
      background: _background,
      font: _font,
      recipients: _recipients(),
    );
    if (!mounted) return;
    if (result.error != null) {
      setState(() => _posting = false);
      showSnack(context, result.error!, isError: true);
      return;
    }
    final n = result.sent;
    final skipped = result.skipped > 0
        ? ' ${result.skipped} couldn\'t get it.'
        : '';
    final navigator = Navigator.of(context);
    navigator.pop(true);
    showSnack(
      navigator.context,
      'Status posted for $n ${n == 1 ? 'person' : 'people'}.$skipped',
    );
  }

  @override
  Widget build(BuildContext context) {
    final people = _recipients().length;
    final color = StatusStyle.backgroundAt(_background);
    final canPost = StatusContent.clean(_text.text).isNotEmpty && !_posting;
    return Scaffold(
      backgroundColor: color,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('New status'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
                  child: TextField(
                    controller: _text,
                    autofocus: true,
                    maxLines: null,
                    textAlign: TextAlign.center,
                    textCapitalization: TextCapitalization.sentences,
                    cursorColor: Colors.white,
                    onChanged: (_) => setState(() {}),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      height: 1.3,
                      fontFamily: StatusStyle.fontFamilyAt(_font),
                    ),
                    inputFormatters: [_CharacterLimit(StatusContent.maxLength)],
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      hintText: 'Type a status',
                      hintStyle: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.page),
              child: Text(
                '${StatusContent.clean(_text.text).runes.length}/${StatusContent.maxLength}',
                style: context.text.bodySmall?.copyWith(color: Colors.white70),
              ),
            ),
            const SizedBox(height: Insets.sm),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Insets.page),
                children: [
                  for (var i = 0; i < StatusStyle.backgrounds.length; i++)
                    Semantics(
                      button: true,
                      selected: i == _background,
                      label: 'Background ${i + 1}',
                      child: GestureDetector(
                        onTap: () => setState(() => _background = i),
                        child: Container(
                          width: 36,
                          height: 36,
                          margin: const EdgeInsets.only(right: Insets.md),
                          decoration: BoxDecoration(
                            color: StatusStyle.backgrounds[i],
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white,
                              width: i == _background ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Insets.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.page),
              child: Row(
                children: [
                  for (var i = 0; i < StatusStyle.fonts.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: Insets.sm),
                      child: ChoiceChip(
                        label: Text(
                          StatusStyle.fonts[i].$1,
                          style: TextStyle(fontFamily: StatusStyle.fonts[i].$2),
                        ),
                        selected: i == _font,
                        onSelected: (_) => setState(() => _font = i),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(Insets.page),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      people == 0
                          ? 'Nobody to send it to yet'
                          : 'Goes to $people ${people == 1 ? 'person' : 'people'} you chat with, for 24 hours',
                      style: context.text.bodySmall?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: canPost ? _post : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: color,
                    ),
                    icon: _posting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded, size: 18),
                    label: const Text('Post'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps the text to [max] characters (not UTF-16 units, so an emoji is one).
class _CharacterLimit extends TextInputFormatter {
  final int max;

  _CharacterLimit(this.max);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.runes.length <= max) return newValue;
    // Pasting more than fits keeps what fits.
    final kept = String.fromCharCodes(newValue.text.runes.take(max));
    return TextEditingValue(
      text: kept,
      selection: TextSelection.collapsed(offset: kept.length),
    );
  }
}
