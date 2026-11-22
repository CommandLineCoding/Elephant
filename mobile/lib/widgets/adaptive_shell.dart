import 'package:flutter/material.dart';
import 'package:mobile/themes/app_themes.dart';

/// How wide a screen has to be (in logical pixels) for the chat list and the
/// open chat to sit side by side: a tablet, or a phone on its side.
const double wideScreenWidth = 840;

/// The width of the chat list when it shares the screen with a chat.
const double listPaneWidth = 380;

bool isWideScreen(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= wideScreenWidth;

/// The right-hand side of a wide screen: where an opened chat appears, so the
/// chat list stays in view. Absent on a narrow screen, where a chat takes over
/// the whole screen.
class DetailPane extends InheritedWidget {
  final GlobalKey<NavigatorState> navigatorKey;

  /// The ID of the chat shown, or null when none is.
  final ValueNotifier<String?> shownChat;

  const DetailPane({
    super.key,
    required this.navigatorKey,
    required this.shownChat,
    required super.child,
  });

  /// The pane above [context], or null on a narrow screen.
  static DetailPane? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DetailPane>();

  /// Shows [page] in the pane, in place of what was there, for the chat
  /// [chatId].
  void show(Widget page, {required String chatId}) {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    shownChat.value = chatId;
    navigator.pushAndRemoveUntil(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => page,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
      (route) => route.isFirst,
    );
  }

  @override
  bool updateShouldNotify(DetailPane oldWidget) =>
      navigatorKey != oldWidget.navigatorKey ||
      shownChat != oldWidget.shownChat;
}

/// Puts [child] (the chat list) beside a pane for the open chat when the screen
/// is wide, and shows [child] alone otherwise.
class AdaptiveShell extends StatefulWidget {
  final Widget child;

  const AdaptiveShell({super.key, required this.child});

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends State<AdaptiveShell> {
  final _detailKey = GlobalKey<NavigatorState>();
  final _shown = ValueNotifier<String?>(null);

  // Keeps the chat list's state (tab, search) when the screen turns wide.
  final _listKey = GlobalKey();

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = KeyedSubtree(key: _listKey, child: widget.child);
    if (!isWideScreen(context)) return list;

    return DetailPane(
      navigatorKey: _detailKey,
      shownChat: _shown,
      child: Scaffold(
        body: Row(
          children: [
            SizedBox(width: listPaneWidth, child: list),
            VerticalDivider(width: 1, color: context.colors.outlineVariant),
            Expanded(
              child: NavigatorPopHandler(
                onPopWithResult: (_) => _detailKey.currentState?.maybePop(),
                child: Navigator(
                  key: _detailKey,
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => const _NoChatYet(),
                  ),
                  observers: [_ShownChatObserver(_shown)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Clears [DetailPane.shownChat] when the pane goes back to its empty state.
class _ShownChatObserver extends NavigatorObserver {
  final ValueNotifier<String?> shown;

  _ShownChatObserver(this.shown);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute?.isFirst ?? true) {
      Future.microtask(() => shown.value = null);
    }
  }
}

class _NoChatYet extends StatelessWidget {
  const _NoChatYet();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(Insets.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.forum_outlined,
                size: 56,
                color: context.colors.onSurfaceVariant,
              ),
              const SizedBox(height: Insets.lg),
              Text('Select a chat', style: context.text.titleMedium),
              const SizedBox(height: Insets.xs),
              Text(
                'Pick a conversation on the left to read and reply.',
                textAlign: TextAlign.center,
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
