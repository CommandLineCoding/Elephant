import 'package:flutter/material.dart';
import 'package:mobile/services/app_lock.dart';
import 'package:mobile/themes/app_themes.dart';

/// Covers the app with the lock screen while [AppLock] says it is locked, and
/// tells it when the app leaves and returns.
class AppLockGate extends StatefulWidget {
  final Widget child;
  final AppLock lock;

  AppLockGate({super.key, required this.child, AppLock? lock})
    : lock = lock ?? AppLock.instance;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _autoAsked = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.lock.addListener(_onChange);
    _onChange();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.lock.removeListener(_onChange);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) widget.lock.didLeave();
    if (state == AppLifecycleState.resumed) widget.lock.didReturn();
  }

  /// Asks for the fingerprint as soon as the lock shows, once. If the person
  /// cancels, they tap Unlock to try again instead of being asked in a loop.
  void _onChange() {
    if (!widget.lock.locked) {
      _autoAsked = false;
      _failed = false;
      return;
    }
    if (_autoAsked) return;
    _autoAsked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (!mounted || !widget.lock.locked) return;
    setState(() => _failed = false);
    final ok = await widget.lock.unlock();
    if (mounted && !ok) setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.lock, widget.lock.callScreenOpen]),
      builder: (context, _) {
        final covered = widget.lock.locked && !widget.lock.callScreenOpen.value;
        return Stack(
          children: [
            // The app is kept in the tree, but nothing in it can be seen,
            // reached or read out while it is covered.
            ExcludeSemantics(
              excluding: covered,
              child: IgnorePointer(ignoring: covered, child: widget.child),
            ),
            if (covered)
              Positioned.fill(
                child: _LockScreen(failed: _failed, onUnlock: _unlock),
              ),
          ],
        );
      },
    );
  }
}

class _LockScreen extends StatelessWidget {
  final bool failed;
  final VoidCallback onUnlock;

  const _LockScreen({required this.failed, required this.onUnlock});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(Insets.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/launcher/elephant.png',
                  width: 88,
                  height: 88,
                ),
                const SizedBox(height: Insets.lg),
                Text(
                  'Elephant is locked',
                  style: context.text.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Insets.sm),
                Text(
                  failed
                      ? 'That didn\'t work. Try again.'
                      : 'Use your fingerprint, face or screen lock to open it.',
                  style: context.text.bodyMedium?.copyWith(
                    color: failed
                        ? context.colors.error
                        : context.colors.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Insets.xl),
                FilledButton.icon(
                  onPressed: onUnlock,
                  icon: const Icon(Icons.lock_open_rounded),
                  label: const Text('Unlock'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
