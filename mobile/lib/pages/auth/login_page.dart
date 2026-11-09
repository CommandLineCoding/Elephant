import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:mobile/pages/settings/appearance.dart';
import 'package:mobile/pages/settings/server_settings.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/surfaces.dart';
import 'package:provider/provider.dart';
import '../../core/constants.dart';
import '../../controllers/auth_state.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isRegister = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    context.read<AuthState>().refreshRegistrationStatus();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _displayNameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Register is only offered while the server accepts new accounts.
  bool _registering(AuthState auth) => _isRegister && !auth.registrationClosed;

  void _setMode(bool register) {
    if (_isRegister == register) return;
    setState(() => _isRegister = register);
    _formKey.currentState?.reset();
    context.read<AuthState>().clearError();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();

    final auth = context.read<AuthState>();
    if (_registering(auth)) {
      await auth.handleRegister(
        _usernameController.text,
        _displayNameController.text,
        _passwordController.text,
      );
    } else {
      await auth.handleLogin(
        _usernameController.text,
        _passwordController.text,
      );
    }
  }

  Future<void> _openServerSettings() async {
    await showServerSettingsSheet(context);
    if (!mounted) return;
    setState(() {});
    context.read<AuthState>().refreshRegistrationStatus();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final registering = _registering(auth);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: ScreenBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 420,
                    minHeight: box.maxHeight,
                  ),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _TopBar(
                          onAppearance: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const AppearanceSettings(),
                            ),
                          ),
                        ),
                        const SizedBox(height: Insets.xxl),
                        _Heading(isRegister: registering),
                        const SizedBox(height: Insets.xl),
                        _buildForm(auth),
                        const SizedBox(height: Insets.xl),
                        _buildOAuth(auth),
                        const Spacer(),
                        const SizedBox(height: Insets.xl),
                        _ServerRow(onTap: _openServerSettings),
                        const SizedBox(height: Insets.lg),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ).animate().fadeIn(duration: 300.ms);
  }

  Widget _buildForm(AuthState auth) {
    final registering = _registering(auth);
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (auth.registrationClosed)
            const _ClosedNote()
          else
            _ModeTabs(isRegister: registering, onChanged: _setMode),
          const SizedBox(height: Insets.xl),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: auth.errorMessage == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(bottom: Insets.lg),
                    child: _ErrorBanner(message: auth.errorMessage!),
                  ),
          ),
          _LabeledField(
            label: 'Username',
            child: TextFormField(
              controller: _usernameController,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              inputFormatters: [
                FilteringTextInputFormatter.allow(
                  registering
                      ? RegExp(r'[a-zA-Z0-9]')
                      : RegExp(r'[a-zA-Z0-9.]'),
                ),
              ],
              decoration: InputDecoration(
                hintText: registering
                    ? 'letters and numbers'
                    : 'e.g. alex.4821',
                helperText: registering
                    ? 'A 4-digit tag is added for you, e.g. alex.4821'
                    : null,
                helperMaxLines: 2,
              ),
              validator: (v) =>
                  AuthState.validateUsername(v, isRegister: registering),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            child: registering
                ? Padding(
                    padding: const EdgeInsets.only(top: Insets.lg),
                    child: _LabeledField(
                      label: 'Display name',
                      child: TextFormField(
                        controller: _displayNameController,
                        textInputAction: TextInputAction.next,
                        textCapitalization: TextCapitalization.words,
                        maxLength: 100,
                        decoration: const InputDecoration(
                          hintText: 'How others see you',
                          counterText: '',
                        ),
                        validator: AuthState.validateDisplayName,
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: Insets.lg),
          _LabeledField(
            label: 'Password',
            child: TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                helperText: registering
                    ? 'At least ${ServerLimits.passwordMin} characters'
                    : null,
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              validator: (v) =>
                  AuthState.validatePassword(v, isRegister: registering),
            ),
          ),
          const SizedBox(height: Insets.xl),
          PrimaryButton(
            label: registering ? 'Create account' : 'Sign in',
            isLoading: auth.isLoading,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }

  Widget _buildOAuth(AuthState auth) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.md),
              child: Text('or continue with', style: context.text.bodySmall),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: Insets.lg),
        Row(
          children: [
            Expanded(
              child: _OAuthButton(
                label: 'Google',
                glyph: 'G',
                onTap: auth.isLoading
                    ? null
                    : () => auth.handleOAuthLogin('google'),
              ),
            ),
            const SizedBox(width: Insets.md),
            Expanded(
              child: _OAuthButton(
                label: 'GitHub',
                icon: Icons.code_rounded,
                onTap: auth.isLoading
                    ? null
                    : () => auth.handleOAuthLogin('github'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The app mark and a quiet appearance button.
class _TopBar extends StatelessWidget {
  final VoidCallback onAppearance;

  const _TopBar({required this.onAppearance});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(
              'assets/launcher/elephant.png',
              width: 36,
              height: 36,
            ),
          ),
          const SizedBox(width: Insets.md),
          Text('Elephant', style: context.text.titleMedium),
          const Spacer(),
          IconButton(
            tooltip: 'Appearance',
            icon: const Icon(Icons.palette_outlined),
            color: context.colors.onSurfaceVariant,
            onPressed: onAppearance,
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final bool isRegister;

  const _Heading({required this.isRegister});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      child: Column(
        key: ValueKey(isRegister),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isRegister ? 'Create your account' : 'Welcome back',
            style: context.text.headlineMedium,
          ),
          const SizedBox(height: Insets.sm),
          Text(
            isRegister
                ? 'Your keys are made on this device and stay on it.'
                : 'Private conversations, end-to-end encrypted.',
            style: context.text.bodyLarge?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A label above its field, instead of a floating label inside it.
class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;

  const _LabeledField({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: context.text.labelLarge),
        const SizedBox(height: Insets.sm),
        child,
      ],
    );
  }
}

/// Shown in place of the Sign in / Register tabs when the server isn't
/// accepting new accounts.
class _ClosedNote extends StatelessWidget {
  const _ClosedNote();

  @override
  Widget build(BuildContext context) {
    return Panel(
      borderRadius: BorderRadius.circular(Radii.md),
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.md,
      ),
      child: Row(
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 18,
            color: context.colors.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Text(
              "This server isn't accepting new accounts.",
              style: context.text.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// Two text tabs with an underline, not a pill: selection is shown by weight
/// and a line, and the accent colour is left for the main button.
class _ModeTabs extends StatelessWidget {
  final bool isRegister;
  final ValueChanged<bool> onChanged;

  const _ModeTabs({required this.isRegister, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.tokens.hairline)),
      ),
      child: Row(
        children: [
          _tab(context, 'Sign in', !isRegister, () => onChanged(false)),
          const SizedBox(width: Insets.xl),
          _tab(context, 'Register', isRegister, () => onChanged(true)),
        ],
      ),
    );
  }

  Widget _tab(
    BuildContext context,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: Insets.md),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? context.colors.onSurface : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: context.text.titleSmall?.copyWith(
            color: selected
                ? context.colors.onSurface
                : context.colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;

  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final error = context.colors.error;
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: error.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: error, size: 20),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Text(
              message,
              style: context.text.bodyMedium?.copyWith(
                color: error,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OAuthButton extends StatelessWidget {
  final String label;
  final String? glyph;
  final IconData? icon;
  final VoidCallback? onTap;

  const _OAuthButton({required this.label, this.glyph, this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (glyph != null)
            Text(
              glyph!,
              style: context.text.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            )
          else
            Icon(icon, size: 20),
          const SizedBox(width: Insets.sm),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

/// Which server the app talks to, as a quiet line at the foot of the page.
class _ServerRow extends StatelessWidget {
  final VoidCallback onTap;

  const _ServerRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Server', style: context.text.bodySmall),
              const SizedBox(width: Insets.sm),
              Flexible(
                child: Text(
                  Env.isDefaultServer
                      ? 'Elephant Cloud'
                      : '${Env.host}:${Env.port}',
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: context.colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
