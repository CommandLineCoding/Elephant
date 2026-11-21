import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/themes/app_themes.dart';

/// The step after a right password for an account with two-step sign-in: a code
/// from the authenticator app, or a recovery code.
class TwoFactorStep extends StatefulWidget {
  /// Called with what was typed.
  final void Function(String code) onSubmit;

  /// Goes back to the password.
  final VoidCallback onCancel;
  final bool busy;
  final String? error;

  const TwoFactorStep({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.busy = false,
    this.error,
  });

  @override
  State<TwoFactorStep> createState() => _TwoFactorStepState();
}

class _TwoFactorStepState extends State<TwoFactorStep> {
  final _code = TextEditingController();
  bool _recovery = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  bool get _ready => _recovery
      ? _code.text.replaceAll(RegExp(r'[\s-]'), '').length == 8
      : _code.text.replaceAll(' ', '').length == 6;

  void _submit() {
    if (_ready && !widget.busy) widget.onSubmit(_code.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Two-step sign-in', style: context.text.headlineSmall),
        const SizedBox(height: Insets.sm),
        Text(
          _recovery
              ? 'Enter one of the recovery codes you saved. Each works once.'
              : 'Enter the 6-digit code from your authenticator app.',
          style: context.text.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Insets.xl),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.lg),
            child: Text(
              widget.error!,
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.error,
              ),
            ),
          ),
        TextField(
          key: ValueKey(_recovery),
          controller: _code,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          textAlign: TextAlign.center,
          style: context.text.headlineSmall?.copyWith(letterSpacing: 4),
          keyboardType: _recovery
              ? TextInputType.visiblePassword
              : TextInputType.number,
          inputFormatters: _recovery
              ? [LengthLimitingTextInputFormatter(12)]
              : [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                  LengthLimitingTextInputFormatter(7),
                ],
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            hintText: _recovery ? 'xxxx-xxxx' : '000000',
          ),
        ),
        const SizedBox(height: Insets.lg),
        FilledButton(
          onPressed: _ready && !widget.busy ? _submit : null,
          child: widget.busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Verify'),
        ),
        const SizedBox(height: Insets.sm),
        TextButton(
          onPressed: () => setState(() {
            _recovery = !_recovery;
            _code.clear();
          }),
          child: Text(
            _recovery ? 'Use my authenticator app' : 'Use a recovery code',
          ),
        ),
        TextButton(onPressed: widget.onCancel, child: const Text('Back')),
      ],
    );
  }
}
