import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/call/call_controller.dart';
import '../../services/app_lock.dart';
import '../../services/calls/call_log.dart';
import '../../themes/app_themes.dart';
import '../../widgets/ui/avatar.dart';

/// The screen for a call: ringing, incoming (accept or decline) and in call
/// (mute, speaker, hang up). It closes itself once the call is over.
class CallPage extends StatefulWidget {
  final CallController controller;

  const CallPage({super.key, required this.controller});

  static Route<void> route(CallController controller) => MaterialPageRoute(
    settings: const RouteSettings(name: routeName),
    builder: (_) => CallPage(controller: controller),
  );

  static const routeName = '/call';

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  Timer? _ticker;
  bool _closing = false;

  CallController get _call => widget.controller;

  @override
  void initState() {
    super.initState();
    _call.addListener(_onChange);
    // Answering shouldn't need unlocking the phone, or the app lock.
    _call.sounds.overLockScreen(true);
    AppLock.instance.callScreenOpen.value = true;
    // The call may already have failed to start.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
    // Redraws the call timer.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_call.phase == CallPhase.connected && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _call.removeListener(_onChange);
    // Leaving the call screen puts the app back behind the lock screen.
    _call.sounds.overLockScreen(false);
    // Not while the tree is being torn down: the lock redraws on this.
    Future.microtask(() => AppLock.instance.callScreenOpen.value = false);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    if (_call.phase == CallPhase.idle && !_closing) {
      _closing = true;
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  String get _status {
    switch (_call.phase) {
      case CallPhase.calling:
        return 'Calling…';
      case CallPhase.ringing:
        return 'Ringing…';
      case CallPhase.incoming:
        return 'Incoming voice call';
      case CallPhase.connecting:
        return 'Connecting…';
      case CallPhase.connected:
        return formatCallDuration(_call.elapsed);
      case CallPhase.ended:
        return _call.endedText ?? 'Call ended';
      case CallPhase.idle:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = _call.phase;
    final name = _call.peerName.isEmpty ? 'Voice call' : _call.peerName;

    return PopScope(
      // Leaving the screen doesn't end the call; it goes on in the background.
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: const Color(0xFF101318),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      tooltip: 'Back to chat',
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      color: Colors.white70,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  const Spacer(flex: 2),
                  ElephantAvatar(
                    name: name,
                    seed: _call.peerId ?? name,
                    size: 112,
                  ),
                  const SizedBox(height: Insets.xl),
                  Text(
                    name,
                    textAlign: TextAlign.center,
                    style: context.text.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Insets.sm),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _status,
                      style: context.text.bodyLarge?.copyWith(
                        color: Colors.white70,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(height: Insets.sm),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.lock_outline_rounded,
                        size: 14,
                        color: Colors.white38,
                      ),
                      const SizedBox(width: Insets.xs),
                      Text(
                        'End-to-end encrypted',
                        style: context.text.bodySmall?.copyWith(
                          color: Colors.white38,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(flex: 3),
                  if (phase == CallPhase.incoming)
                    _IncomingActions(call: _call)
                  else if (phase != CallPhase.ended)
                    _InCallActions(call: _call),
                  const SizedBox(height: Insets.xxl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IncomingActions extends StatelessWidget {
  final CallController call;

  const _IncomingActions({required this.call});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundButton(
          icon: Icons.call_end_rounded,
          label: 'Decline',
          background: _hangUpRed,
          onPressed: call.decline,
        ),
        _RoundButton(
          icon: Icons.call_rounded,
          label: 'Accept',
          background: const Color(0xFF2E9D5B),
          onPressed: call.accept,
        ),
      ],
    );
  }
}

class _InCallActions extends StatelessWidget {
  final CallController call;

  const _InCallActions({required this.call});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundButton(
          icon: call.muted ? Icons.mic_off_rounded : Icons.mic_none_rounded,
          label: call.muted ? 'Unmute' : 'Mute',
          selected: call.muted,
          onPressed: call.toggleMute,
        ),
        _RoundButton(
          icon: Icons.call_end_rounded,
          label: 'End call',
          background: _hangUpRed,
          onPressed: call.hangUp,
        ),
        _RoundButton(
          icon: Icons.volume_up_rounded,
          label: call.speaker ? 'Speaker on' : 'Speaker',
          selected: call.speaker,
          onPressed: call.toggleSpeaker,
        ),
      ],
    );
  }
}

const _hangUpRed = Color(0xFFD64545);

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? background;
  final bool selected;

  const _RoundButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.background,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final fill =
        background ?? (selected ? Colors.white : Colors.white.withAlpha(30));
    final iconColor = background != null
        ? Colors.white
        : (selected ? const Color(0xFF101318) : Colors.white);

    return Semantics(
      button: true,
      toggled: background == null ? selected : null,
      label: label,
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: fill,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: SizedBox(
                width: 68,
                height: 68,
                child: Icon(icon, color: iconColor, size: 30),
              ),
            ),
          ),
          const SizedBox(height: Insets.sm),
          Text(
            label,
            style: context.text.bodySmall?.copyWith(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
