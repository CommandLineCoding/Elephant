import 'package:flutter/material.dart';
import 'package:mobile/models/signed_in_device.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/services/signed_in_devices.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/surfaces.dart';

/// The devices the person is signed in on, with a way to sign each one out,
/// or all but this one.
class SignedInDevicesPage extends StatefulWidget {
  final SignedInDevicesApi api;

  /// Tells the page what time it is, so a test can fix it.
  final DateTime Function() now;

  const SignedInDevicesPage({
    super.key,
    this.api = const ServerSignedInDevicesApi(),
    this.now = DateTime.now,
  });

  @override
  State<SignedInDevicesPage> createState() => _SignedInDevicesPageState();
}

class _SignedInDevicesPageState extends State<SignedInDevicesPage> {
  List<SignedInDevice>? _devices;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final devices = await widget.api.list();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ApiService.errorMessage(
          e,
          fallback: 'Couldn\'t load your devices.',
        );
      });
    }
  }

  /// Runs [action], then reloads the list. Says why if it failed.
  Future<void> _change(
    Future<void> Function() action, {
    required String done,
  }) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      showSnack(context, done);
    } catch (e) {
      if (!mounted) return;
      showSnack(
        context,
        ApiService.errorMessage(e, fallback: 'Couldn\'t sign out.'),
        isError: true,
      );
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _signOut(SignedInDevice device) async {
    final confirmed = await confirmAction(
      context,
      title: 'Sign out ${device.title}?',
      message:
          'It is signed out of your account at once and has to sign in '
          'again. Messages already on it stay there.',
      confirmLabel: 'Sign out',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _change(
      () => widget.api.signOut(device.id),
      done: '${device.title} was signed out',
    );
  }

  Future<void> _signOutOthers() async {
    final confirmed = await confirmAction(
      context,
      title: 'Sign out all other devices?',
      message:
          'Every device except this one is signed out at once and has to '
          'sign in again.',
      confirmLabel: 'Sign out others',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _change(
      widget.api.signOutOthers,
      done: 'Your other devices were signed out',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const ElephantAppBar(title: Text('Signed-in devices')),
      body: ScreenBackground(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final devices = _devices;
    if (devices == null) {
      if (_error != null) {
        return EmptyState(
          icon: Icons.cloud_off_rounded,
          title: 'Couldn\'t load your devices',
          message: _error!,
          actionLabel: 'Try again',
          onAction: () {
            setState(() => _error = null);
            _load();
          },
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    final others = devices.where((d) => !d.isCurrent).toList();
    final now = widget.now();
    return ListView(
      padding: const EdgeInsets.only(top: Insets.lg, bottom: Insets.xxl),
      children: [
        const PageIntro(
          icon: Icons.devices_rounded,
          title: 'Where you\'re signed in',
          body:
              'If you see a device you don\'t know, or you lost a phone, sign '
              'it out here. Change your password if you think someone else '
              'has it.',
        ),
        const SectionLabel('This device'),
        Section(
          children: [
            for (final device in devices.where((d) => d.isCurrent))
              _tile(context, device, now),
            if (!devices.any((d) => d.isCurrent))
              const ElephantTile(
                icon: Icons.smartphone_rounded,
                title: 'This device',
                subtitle: 'Not in the list. Sign in again to see it here.',
                showChevron: false,
              ),
          ],
        ),
        if (others.isNotEmpty) ...[
          const SectionLabel('Other devices'),
          Section(children: [for (final d in others) _tile(context, d, now)]),
          const SizedBox(height: Insets.xl),
          Section(
            children: [
              ElephantTile(
                icon: Icons.logout_rounded,
                title: 'Sign out all other devices',
                destructive: true,
                showChevron: false,
                onTap: _busy ? null : _signOutOthers,
              ),
            ],
          ),
        ] else ...[
          const SizedBox(height: Insets.xl),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.page + 4),
            child: Text(
              'You\'re not signed in anywhere else.',
              textAlign: TextAlign.center,
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _tile(BuildContext context, SignedInDevice device, DateTime now) {
    return ElephantTile(
      icon: device.isCurrent
          ? Icons.smartphone_rounded
          : Icons.devices_other_rounded,
      title: device.title,
      subtitle: device.isCurrent
          ? 'This device · ${describeLastActive(device.lastUsedAt, now)}'
          : describeLastActive(device.lastUsedAt, now),
      showChevron: false,
      trailing: device.isCurrent
          ? null
          : IconButton(
              tooltip: 'Sign out ${device.title}',
              icon: const Icon(Icons.logout_rounded),
              onPressed: _busy ? null : () => _signOut(device),
            ),
    );
  }
}
