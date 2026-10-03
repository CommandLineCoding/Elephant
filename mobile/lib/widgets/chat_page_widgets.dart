import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:intl/intl.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/home_page_widgets.dart';
import 'package:mobile/widgets/ui/avatar.dart';

/// Chat header: back, avatar, name and a live status line.
class ChatHeader extends StatelessWidget implements PreferredSizeWidget {
  final String name;
  final String seed;
  final bool isGroup;
  final String subtitle;
  final bool? isOnline;
  final bool highlightSubtitle;
  final VoidCallback? onTitleTap;
  final List<Widget>? actions;

  const ChatHeader({
    super.key,
    required this.name,
    required this.seed,
    required this.isGroup,
    required this.subtitle,
    this.isOnline,
    this.highlightSubtitle = false,
    this.onTitleTap,
    this.actions,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 6);

  @override
  Widget build(BuildContext context) {
    final glass = context.glass;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: glass.blur, sigmaY: glass.blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: glass.glassStrongFill,
            border: Border(bottom: BorderSide(color: glass.glassBorder)),
          ),
          child: AppBar(
            toolbarHeight: kToolbarHeight + 6,
            backgroundColor: Colors.transparent,
            titleSpacing: 0,
            actions: actions,
            title: InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: onTitleTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Row(
                  children: [
                    Hero(
                      tag: 'avatar-$seed',
                      child: ElephantAvatar(
                        name: name,
                        seed: seed,
                        isGroup: isGroup,
                        size: 40,
                        isOnline: isOnline,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: Text(
                              subtitle,
                              key: ValueKey(subtitle),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: highlightSubtitle
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: highlightSubtitle
                                    ? context.colors.primary
                                    : context.colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ChatBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final bool isGroup;
  final bool isFirstInRun;
  final bool isLastInRun;
  final String? senderName;
  final String? senderSeed;
  final String? quotedAuthor;
  final bool highlighted;
  final VoidCallback? onQuoteTap;

  const ChatBubble({
    super.key,
    required this.message,
    required this.isMe,
    this.isGroup = false,
    this.isFirstInRun = true,
    this.isLastInRun = true,
    this.senderName,
    this.senderSeed,
    this.quotedAuthor,
    this.highlighted = false,
    this.onQuoteTap,
  });

  @override
  Widget build(BuildContext context) {
    final glass = context.glass;
    final isLocked = message.content.startsWith(MessageEnvelope.lockedPrefix);
    final textColor = isMe ? glass.onAccent : glass.incomingText;
    final metaColor = textColor.withValues(alpha: isMe ? 0.78 : 0.55);

    const big = Radius.circular(Radii.bubble);
    const small = Radius.circular(6);
    final radius = BorderRadius.only(
      topLeft: !isMe && !isFirstInRun ? small : big,
      bottomLeft: !isMe && !isLastInRun ? small : (!isMe ? small : big),
      topRight: isMe && !isFirstInRun ? small : big,
      bottomRight: isMe && !isLastInRun ? small : (isMe ? small : big),
    );

    final showGroupAvatar = isGroup && !isMe;

    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.76,
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        gradient: isMe ? glass.accentGradient : null,
        color: isMe ? null : glass.incomingBubble,
        borderRadius: radius,
        border: isMe ? null : Border.all(color: glass.glassBorder),
        boxShadow: [
          BoxShadow(
            color: highlighted
                ? context.colors.primary.withValues(alpha: 0.55)
                : Colors.black.withValues(alpha: isMe ? 0.10 : 0.05),
            blurRadius: highlighted ? 18 : 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isGroup && !isMe && isFirstInRun && senderName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  senderName!,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: ElephantAvatar.colorFor(senderSeed ?? senderName!),
                  ),
                ),
              ),
            if (message.quotedMessage != null)
              _QuoteBlock(
                quote: message.quotedMessage!,
                author: quotedAuthor,
                onMe: isMe,
                onTap: onQuoteTap,
              ),
            if (isLocked)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline_rounded, size: 15, color: metaColor),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      message.content.substring(
                        MessageEnvelope.lockedPrefix.length,
                      ),
                      style: TextStyle(
                        color: metaColor,
                        fontStyle: FontStyle.italic,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              )
            else
              MarkdownBody(
                data: message.content,
                softLineBreak: true,
                styleSheet: _markdownStyle(context, textColor),
              ),
            const SizedBox(height: 3),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.isEdited) ...[
                    Text(
                      'edited',
                      style: TextStyle(
                        color: metaColor,
                        fontSize: 10.5,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    DateFormat.jm().format(message.createdAt),
                    style: TextStyle(
                      color: metaColor,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (isMe && !isGroup) ...[
                    const SizedBox(width: 4),
                    DeliveryTick(
                      isPending: message.isPending,
                      isRead: message.isRead,
                      color: metaColor,
                      readColor: textColor,
                      size: 15,
                    ),
                  ] else if (isMe && message.isPending) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.schedule_rounded, size: 13, color: metaColor),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(
        top: isFirstInRun ? 6 : 1.5,
        bottom: isLastInRun ? 2 : 0,
      ),
      child: Row(
        mainAxisAlignment: isMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showGroupAvatar) ...[
            SizedBox(
              width: 30,
              child: isLastInRun
                  ? ElephantAvatar(
                      name: senderName ?? '?',
                      seed: senderSeed ?? '',
                      size: 28,
                    )
                  : null,
            ),
            const SizedBox(width: 6),
          ],
          Flexible(child: bubble),
        ],
      ),
    );
  }

  MarkdownStyleSheet _markdownStyle(BuildContext context, Color textColor) {
    final base = TextStyle(color: textColor, fontSize: 15.5, height: 1.35);
    return MarkdownStyleSheet(
      p: base,
      strong: base.copyWith(fontWeight: FontWeight.w800),
      em: base.copyWith(fontStyle: FontStyle.italic),
      del: base.copyWith(
        decoration: TextDecoration.lineThrough,
        color: textColor.withValues(alpha: 0.7),
      ),
      a: base.copyWith(
        decoration: TextDecoration.underline,
        fontWeight: FontWeight.w600,
      ),
      code: TextStyle(
        color: textColor,
        fontFamily: 'monospace',
        fontSize: 14,
        backgroundColor: textColor.withValues(alpha: 0.12),
      ),
      codeblockDecoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: textColor.withValues(alpha: 0.5), width: 3),
        ),
      ),
      listBullet: base,
    );
  }
}

class _QuoteBlock extends StatelessWidget {
  final QuotedMessage quote;
  final String? author;
  final bool onMe;
  final VoidCallback? onTap;

  const _QuoteBlock({
    required this.quote,
    this.author,
    required this.onMe,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final glass = context.glass;
    final base = onMe ? glass.onAccent : glass.incomingText;
    final accent = onMe ? glass.onAccent : context.colors.primary;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6, top: 2),
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 7),
        decoration: BoxDecoration(
          color: base.withValues(alpha: onMe ? 0.16 : 0.06),
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border(left: BorderSide(color: accent, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (author != null)
              Text(
                author!,
                style: TextStyle(
                  color: accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            Text(
              quote.content.replaceAll('\n', ' '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: base.withValues(alpha: 0.8),
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Today" / "Yesterday" / date pill between days.
class DaySeparator extends StatelessWidget {
  final DateTime date;

  const DaySeparator({super.key, required this.date});

  static String label(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return DateFormat.EEEE().format(date);
    if (date.year == now.year) return DateFormat.MMMMd().format(date);
    return DateFormat.yMMMMd().format(date);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 14),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: context.glass.glassStrongFill,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: context.glass.glassBorder),
        ),
        child: Text(
          label(date),
          style: context.text.labelSmall?.copyWith(
            letterSpacing: 0.3,
            fontSize: 11.5,
          ),
        ),
      ),
    );
  }
}

/// Explains who can read this chat, shown above the first message.
class EncryptionNotice extends StatelessWidget {
  final bool isGroup;

  const EncryptionNotice({super.key, required this.isGroup});

  @override
  Widget build(BuildContext context) {
    final color = isGroup ? context.glass.warning : context.glass.success;
    return Center(
      child: Container(
        margin: const EdgeInsets.fromLTRB(28, 12, 28, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isGroup ? Icons.lock_open_rounded : Icons.lock_rounded,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                isGroup
                    ? 'Group messages are protected in transit but are not end-to-end encrypted yet.'
                    : 'Messages are end-to-end encrypted. Only you and this contact can read them.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: color,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Three bouncing dots in an incoming bubble.
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glass = context.glass;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 6, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: glass.incomingBubble,
          border: Border.all(color: glass.glassBorder),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(Radii.bubble),
            topRight: Radius.circular(Radii.bubble),
            bottomRight: Radius.circular(Radii.bubble),
            bottomLeft: Radius.circular(6),
          ),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final t = (_controller.value - i * 0.18) % 1.0;
                final lift = t < 0.4
                    ? Curves.easeOut.transform(t / 0.4)
                    : (t < 0.8
                          ? 1 - Curves.easeIn.transform((t - 0.4) / 0.4)
                          : 0.0);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2.5),
                  child: Transform.translate(
                    offset: Offset(0, -4 * lift),
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: context.colors.primary.withValues(
                          alpha: 0.45 + 0.55 * lift,
                        ),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}

/// Banner above the composer for replying to or editing a message.
class ComposerBanner extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onClose;

  const ComposerBanner({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.sm),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: context.colors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border(
          left: BorderSide(color: context.colors.primary, width: 3),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.colors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: context.colors.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                  ),
                ),
                Text(
                  body.replaceAll('\n', ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.colors.onSurfaceVariant,
                    fontSize: 13.5,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// Glass composer: growing text field, byte budget near the limit, and a
/// gradient send button.
class ChatComposer extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function(String) onSend;
  final ValueChanged<bool>? onTypingChanged;
  final int byteLimit;
  final Widget? banner;
  final bool isEditing;

  const ChatComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.byteLimit,
    this.onTypingChanged,
    this.banner,
    this.isEditing = false,
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  bool _isTyping = false;
  bool _sending = false;
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    widget.controller.removeListener(_onChanged);
    if (_isTyping) widget.onTypingChanged?.call(false);
    super.dispose();
  }

  int get _bytes => utf8.encode(widget.controller.text.trim()).length;

  void _onChanged() {
    setState(() {});
    if (widget.isEditing) return;

    final hasText = widget.controller.text.trim().isNotEmpty;
    if (hasText && !_isTyping) {
      _isTyping = true;
      widget.onTypingChanged?.call(true);
    }
    _typingTimer?.cancel();
    if (hasText) {
      _typingTimer = Timer(const Duration(milliseconds: 2500), _stopTyping);
    } else {
      _stopTyping();
    }
  }

  void _stopTyping() {
    if (_isTyping) {
      _isTyping = false;
      widget.onTypingChanged?.call(false);
    }
  }

  Future<void> _submit() async {
    final text = widget.controller.text.trim();
    if (text.isEmpty || _sending || _bytes > widget.byteLimit) return;
    setState(() => _sending = true);
    _typingTimer?.cancel();
    _stopTyping();
    try {
      await widget.onSend(text);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final glass = context.glass;
    final bytes = _bytes;
    final over = bytes > widget.byteLimit;
    final nearLimit = bytes > widget.byteLimit * 0.8;
    final canSend =
        widget.controller.text.trim().isNotEmpty && !over && !_sending;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: glass.blur, sigmaY: glass.blur),
        child: Container(
          decoration: BoxDecoration(
            color: glass.glassStrongFill,
            border: Border(top: BorderSide(color: glass.glassBorder)),
          ),
          padding: EdgeInsets.only(
            top: Insets.sm,
            bottom: Insets.sm + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: widget.banner ?? const SizedBox(width: double.infinity),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: widget.controller,
                        focusNode: widget.focusNode,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        minLines: 1,
                        maxLines: 6,
                        style: TextStyle(
                          fontSize: 15.5,
                          color: over
                              ? context.colors.error
                              : context.colors.onSurface,
                        ),
                        decoration: InputDecoration(
                          hintText: widget.isEditing
                              ? 'Edit message'
                              : 'Message',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(Radii.xl),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(Radii.xl),
                            borderSide: over
                                ? BorderSide(color: context.colors.error)
                                : BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(Radii.xl),
                            borderSide: BorderSide(
                              color: over
                                  ? context.colors.error
                                  : context.colors.primary.withValues(
                                      alpha: 0.6,
                                    ),
                            ),
                          ),
                          suffixIcon: nearLimit
                              ? Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: Center(
                                    widthFactor: 1,
                                    child: Text(
                                      '${widget.byteLimit - bytes}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: over
                                            ? context.colors.error
                                            : context.colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    AnimatedScale(
                      scale: canSend ? 1 : 0.88,
                      duration: const Duration(milliseconds: 180),
                      child: AnimatedOpacity(
                        opacity: canSend ? 1 : 0.45,
                        duration: const Duration(milliseconds: 180),
                        child: Material(
                          color: Colors.transparent,
                          shape: const CircleBorder(),
                          child: Ink(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: glass.accentGradient,
                            ),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: canSend ? _submit : null,
                              child: SizedBox(
                                width: 46,
                                height: 46,
                                child: _sending
                                    ? Padding(
                                        padding: const EdgeInsets.all(13),
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: glass.onAccent,
                                        ),
                                      )
                                    : Icon(
                                        widget.isEditing
                                            ? Icons.check_rounded
                                            : Icons.arrow_upward_rounded,
                                        color: glass.onAccent,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
