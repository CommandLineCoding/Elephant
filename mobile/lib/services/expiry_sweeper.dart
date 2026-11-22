import 'dart:async';

/// Clears out disappearing messages as their time comes, while the app is open.
///
/// Reads already skip expired messages, so this is about the stored copies going
/// away, and the open chat and the inbox catching up without a refresh.
class ExpirySweeper {
  final Duration every;
  final DateTime Function() clock;
  final Future<int> Function(DateTime now) deleteExpired;
  final void Function(DateTime now) onSweep;
  final void Function() onDeleted;

  Timer? _timer;
  bool _sweeping = false;

  ExpirySweeper({
    required this.deleteExpired,
    required this.onSweep,
    required this.onDeleted,
    this.every = const Duration(seconds: 30),
    this.clock = DateTime.now,
  });

  void start() {
    _timer ??= Timer.periodic(every, (_) => sweep());
    sweep();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass. Overlapping passes are skipped.
  Future<void> sweep() async {
    if (_sweeping) return;
    _sweeping = true;
    try {
      final now = clock();
      onSweep(now);
      final deleted = await deleteExpired(now);
      if (deleted > 0) onDeleted();
    } catch (_) {
      // Try again on the next tick.
    } finally {
      _sweeping = false;
    }
  }
}
