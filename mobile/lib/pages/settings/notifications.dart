import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile/services/push/push_prefs.dart';
import 'package:mobile/services/push/push_service.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/surfaces.dart';
import 'package:url_launcher/url_launcher.dart';

/// Turns new-message notifications on or off. They work through UnifiedPush
/// instead of Google's push service, so they need a distributor app such as
/// ntfy, and never contain the message text.
class NotificationsSettingsPage extends StatefulWidget {
  const NotificationsSettingsPage({super.key});

  @override
  State<NotificationsSettingsPage> createState() =>
      _NotificationsSettingsPageState();
}

class _NotificationsSettingsPageState extends State<NotificationsSettingsPage> {
  static final _distributorsUrl = Uri.parse(
    'https://unifiedpush.org/users/distributors/',
  );

  final PushService _push = PushService.instance;

  bool _loaded = false;
  bool _enabled = false;
  bool _showNames = true;
  bool _busy = false;
  String? _distributor;
  String? _hint;

  /// Set when the distributor hasn't answered for a while, which usually means
  /// it has never been opened: Android doesn't deliver broadcasts to an app
  /// that was installed but never launched.
  Timer? _slowTimer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _push.status.addListener(_onStatus);
    _load();
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _push.status.removeListener(_onStatus);
    super.dispose();
  }

  void _onStatus() {
    if (!mounted) return;
    setState(() => _slow = false);
    if (_enabled && _distributor == null) _loadDistributor();

    _slowTimer?.cancel();
    if (_push.status.value == PushStatus.registering) {
      _slowTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _push.status.value == PushStatus.registering) {
          setState(() => _slow = true);
        }
      });
    }
  }

  Future<void> _loadDistributor() async {
    final distributor = await _push.currentDistributor();
    if (mounted) setState(() => _distributor = distributor);
  }

  Future<void> _load() async {
    final enabled = await _push.isEnabled;
    final showNames = await PushPrefs.showNames();
    final distributor = enabled ? await _push.currentDistributor() : null;
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _showNames = showNames;
      _distributor = distributor;
      _loaded = true;
    });
  }

  Future<String?> _chooseDistributor(List<String> distributors) {
    return showActionSheet<String>(
      context,
      header: const ListTile(
        title: Text('Choose a distributor'),
        subtitle: Text(
          'The app that delivers push notifications to your phone.',
        ),
      ),
      actions: [
        for (final id in distributors)
          SheetAction(
            icon: Icons.notifications_active_outlined,
            label: distributorLabel(id),
            value: id,
          ),
      ],
    );
  }

  Future<void> _toggle(bool on) async {
    setState(() {
      _busy = true;
      _hint = null;
    });
    try {
      if (!on) {
        await _push.disable();
        if (mounted) setState(() => _enabled = false);
        return;
      }

      final result = await _push.enable(choose: _chooseDistributor);
      if (!mounted) return;
      switch (result) {
        case PushEnableResult.ok:
          final distributor = await _push.currentDistributor();
          if (mounted) {
            setState(() {
              _enabled = true;
              _distributor = distributor;
            });
          }
        case PushEnableResult.permissionDenied:
          setState(
            () => _hint =
                'Elephant needs permission to show notifications. Allow it in '
                'Android settings → Apps → Elephant → Notifications.',
          );
        case PushEnableResult.noDistributor:
          setState(
            () => _hint =
                'No UnifiedPush distributor is installed. Install one, such as '
                'ntfy, and then try again.',
          );
        case PushEnableResult.cancelled:
          break;
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, "Couldn't change notifications.", isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setShowNames(bool value) async {
    setState(() => _showNames = value);
    await PushPrefs.setShowNames(value);
  }

  String _statusText() {
    if (!_enabled) return 'Off';
    switch (_push.status.value) {
      case PushStatus.active:
        return 'On, through ${_distributor == null ? 'your distributor' : distributorLabel(_distributor!)}';
      case PushStatus.failed:
        return _push.problem ?? 'Something went wrong.';
      case PushStatus.registering:
        if (!_slow) return 'Connecting…';
        final name = _distributor == null
            ? 'your distributor app'
            : distributorLabel(_distributor!);
        return 'Waiting for $name. Open it once, then turn this off and on again.';
      case PushStatus.off:
        return 'On';
    }
  }

  @override
  Widget build(BuildContext context) {
    final failed = _enabled && _push.status.value == PushStatus.failed;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: ElephantAppBar(
        title: const Text('Notifications'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: ScreenBackground(
        child: ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight + Insets.lg,
            bottom: Insets.xxl + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.page),
              child: Panel(
                borderRadius: BorderRadius.circular(Radii.xl),
                padding: const EdgeInsets.all(Insets.xl),
                child: Column(
                  children: [
                    AccentBox(
                      shape: BoxShape.circle,
                      padding: const EdgeInsets.all(16),
                      child: Icon(
                        Icons.notifications_rounded,
                        size: 34,
                        color: context.tokens.onAccent,
                      ),
                    ),
                    const SizedBox(height: Insets.lg),
                    Text(
                      'Alerts without Google',
                      style: context.text.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: Insets.sm),
                    Text(
                      'Elephant uses UnifiedPush instead of Google\'s push '
                      'service. Your server sends a tiny ping when you have a '
                      'new message and nothing else, so the notification only '
                      'says who it\'s from, never what was said.',
                      textAlign: TextAlign.center,
                      style: context.text.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SectionLabel('Message alerts'),
            Section(
              children: [
                ElephantTile(
                  icon: Icons.notifications_active_outlined,
                  iconColor: failed ? context.colors.error : null,
                  title: 'Notify me about new messages',
                  subtitle: _loaded ? _statusText() : null,
                  showChevron: false,
                  trailing: Switch(
                    value: _enabled,
                    onChanged: _loaded && !_busy ? _toggle : null,
                  ),
                ),
                if (_enabled)
                  ElephantTile(
                    icon: Icons.person_outline_rounded,
                    title: 'Show who it\'s from',
                    subtitle: _showNames
                        ? 'The sender\'s name is shown (hidden on the lock screen)'
                        : 'Notifications just say "New message"',
                    showChevron: false,
                    trailing: Switch(
                      value: _showNames,
                      onChanged: _setShowNames,
                    ),
                  ),
              ],
            ),
            if (_hint != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.page,
                  Insets.md,
                  Insets.page,
                  0,
                ),
                child: Panel(
                  borderRadius: BorderRadius.circular(Radii.lg),
                  padding: const EdgeInsets.all(Insets.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_hint!, style: context.text.bodyMedium),
                      if (_hint!.contains('distributor')) ...[
                        const SizedBox(height: Insets.sm),
                        TextButton.icon(
                          onPressed: () => launchUrl(
                            _distributorsUrl,
                            mode: LaunchMode.externalApplication,
                          ),
                          icon: const Icon(Icons.open_in_new_rounded, size: 18),
                          label: const Text('See distributors'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
