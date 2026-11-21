import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/services/two_factor.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/surfaces.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Turn two-step sign-in on or off: a code from an authenticator app is needed,
/// as well as the password, to sign in.
class TwoStepSignInPage extends StatefulWidget {
  final TwoFactorApi api;

  const TwoStepSignInPage({super.key, this.api = const ServerTwoFactorApi()});

  @override
  State<TwoStepSignInPage> createState() => _TwoStepSignInPageState();
}

class _TwoStepSignInPageState extends State<TwoStepSignInPage> {
  TwoFactorStatus? _status;
  String? _loadError;

  /// Set while someone is turning it on: the secret to scan.
  TwoFactorSetup? _setup;

  /// Set once it is on, until they say they saved them: shown only this once.
  List<String>? _recoveryCodes;

  bool _busy = false;
  String? _error;
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final status = await widget.api.status();
      if (mounted) setState(() => _status = status);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = ApiService.errorMessage(
            e,
            fallback: 'Couldn\'t load your settings.',
          );
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = ApiService.errorMessage(
            e,
            fallback: 'Something went wrong.',
          );
        });
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _start() => _run(() async {
    final setup = await widget.api.start();
    if (mounted) {
      setState(() {
        _setup = setup;
        _code.clear();
      });
    }
  });

  Future<void> _confirm() => _run(() async {
    final codes = await widget.api.enable(_code.text.trim());
    if (!mounted) return;
    setState(() {
      _recoveryCodes = codes;
      _setup = null;
      _status = const TwoFactorStatus(enabled: true, recoveryCodesLeft: 10);
    });
    await _load();
  });

  Future<void> _turnOff() async {
    final result = await showDialog<({String password, String code})>(
      context: context,
      builder: (_) => const _TurnOffDialog(),
    );
    if (result == null || !mounted) return;
    await _run(() async {
      await widget.api.disable(result.password, result.code);
      if (!mounted) return;
      setState(() => _status = const TwoFactorStatus());
      showSnack(context, 'Two-step sign-in is off');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const ElephantAppBar(title: Text('Two-step sign-in')),
      body: ScreenBackground(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final status = _status;
    if (status == null) {
      if (_loadError != null) {
        return EmptyState(
          icon: Icons.cloud_off_rounded,
          title: 'Couldn\'t load this',
          message: _loadError!,
          actionLabel: 'Try again',
          onAction: _load,
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight + Insets.lg;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        Insets.page,
        top,
        Insets.page,
        Insets.xxl + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        if (_recoveryCodes != null)
          _recoveryStep(context, _recoveryCodes!)
        else if (_setup != null)
          _scanStep(context, _setup!)
        else if (status.enabled)
          _onStep(context, status)
        else
          _offStep(context),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: Insets.lg),
            child: Text(
              _error!,
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget _offStep(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'A leaked password would not be enough',
        style: context.text.headlineSmall,
      ),
      const SizedBox(height: Insets.sm),
      Text(
        'With two-step sign-in, signing in with your password also asks for a '
        '6-digit code from an authenticator app on your phone (such as Aegis, '
        'FreeOTP or any TOTP app). Signing in with Google or GitHub is '
        'unchanged.',
        style: context.text.bodyMedium?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: Insets.xl),
      FilledButton(
        onPressed: _busy ? null : _start,
        child: const Text('Turn on'),
      ),
    ],
  );

  Widget _scanStep(BuildContext context, TwoFactorSetup setup) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Add Elephant to your authenticator app',
        style: context.text.titleLarge,
      ),
      const SizedBox(height: Insets.sm),
      Text(
        'Scan this code with the app, or type the key in. Then enter the code '
        'it shows to turn two-step sign-in on.',
        style: context.text.bodyMedium?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: Insets.lg),
      Center(
        child: Container(
          color: Colors.white,
          padding: const EdgeInsets.all(12),
          child: QrImageView(data: setup.uri, size: 200),
        ),
      ),
      const SizedBox(height: Insets.md),
      Section(
        children: [
          ElephantTile(
            icon: Icons.key_rounded,
            title: setup.spacedSecret,
            subtitle: 'Key · tap to copy',
            showChevron: false,
            trailing: const Icon(Icons.copy_rounded, size: 18),
            onTap: () {
              Clipboard.setData(ClipboardData(text: setup.secret));
              showSnack(context, 'Key copied');
            },
          ),
        ],
      ),
      const SizedBox(height: Insets.lg),
      TextField(
        controller: _code,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: context.text.headlineSmall?.copyWith(letterSpacing: 4),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
          LengthLimitingTextInputFormatter(7),
        ],
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(hintText: '000000'),
      ),
      const SizedBox(height: Insets.md),
      FilledButton(
        onPressed: _busy || _code.text.replaceAll(' ', '').length != 6
            ? null
            : _confirm,
        child: const Text('Turn on'),
      ),
      TextButton(
        onPressed: _busy ? null : () => setState(() => _setup = null),
        child: const Text('Cancel'),
      ),
    ],
  );

  Widget _recoveryStep(BuildContext context, List<String> codes) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Save your recovery codes', style: context.text.titleLarge),
      const SizedBox(height: Insets.sm),
      Text(
        'If you lose your phone, each of these signs you in once. They are '
        'shown only now. Keep them somewhere safe, not on this phone alone.',
        style: context.text.bodyMedium?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: Insets.lg),
      Section(
        children: [
          for (final c in codes)
            ElephantTile(
              icon: Icons.pin_outlined,
              title: c,
              showChevron: false,
            ),
        ],
      ),
      const SizedBox(height: Insets.lg),
      OutlinedButton.icon(
        onPressed: () {
          Clipboard.setData(ClipboardData(text: codes.join('\n')));
          showSnack(context, 'Codes copied');
        },
        icon: const Icon(Icons.copy_rounded),
        label: const Text('Copy all'),
      ),
      const SizedBox(height: Insets.sm),
      FilledButton(
        onPressed: () => setState(() => _recoveryCodes = null),
        child: const Text('I\'ve saved them'),
      ),
    ],
  );

  Widget _onStep(BuildContext context, TwoFactorStatus status) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Section(
        children: [
          ElephantTile(
            icon: Icons.verified_user_rounded,
            iconColor: context.tokens.success,
            title: 'Two-step sign-in is on',
            subtitle:
                '${status.recoveryCodesLeft} recovery '
                '${status.recoveryCodesLeft == 1 ? 'code' : 'codes'} left',
            showChevron: false,
          ),
        ],
      ),
      const SizedBox(height: Insets.xl),
      Section(
        children: [
          ElephantTile(
            icon: Icons.no_encryption_gmailerrorred_rounded,
            title: 'Turn off',
            subtitle: 'Needs your password and a code',
            destructive: true,
            showChevron: false,
            onTap: _busy ? null : _turnOff,
          ),
        ],
      ),
    ],
  );
}

/// Asks for the password and a code before two-step sign-in is turned off.
class _TurnOffDialog extends StatefulWidget {
  const _TurnOffDialog();

  @override
  State<_TurnOffDialog> createState() => _TurnOffDialogState();
}

class _TurnOffDialogState extends State<_TurnOffDialog> {
  final _password = TextEditingController();
  final _code = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _ready => _password.text.isNotEmpty && _code.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Turn off two-step sign-in?'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Enter your password and a code from your authenticator app (or a '
            'recovery code).',
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: Insets.lg),
          TextField(
            controller: _password,
            obscureText: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Password'),
          ),
          const SizedBox(height: Insets.md),
          TextField(
            controller: _code,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Code'),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.error,
            foregroundColor: context.colors.onError,
          ),
          onPressed: _ready
              ? () => Navigator.pop(context, (
                  password: _password.text,
                  code: _code.text.trim(),
                ))
              : null,
          child: const Text('Turn off'),
        ),
      ],
    );
  }
}
