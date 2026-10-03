import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:mobile/pages/settings/appearance.dart';
import 'package:mobile/pages/settings/server_settings.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/glass.dart';
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
  void dispose() {
    _usernameController.dispose();
    _displayNameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

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
    if (_isRegister) {
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
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: AmbientBackground(
        animate: true,
        intensity: 1.2,
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.xl,
                    72,
                    Insets.xl,
                    Insets.xl,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children:
                          [
                                _Brand(isRegister: _isRegister),
                                const SizedBox(height: Insets.xxl),
                                GlassSurface(
                                  strong: true,
                                  borderRadius: BorderRadius.circular(Radii.xl),
                                  padding: const EdgeInsets.all(Insets.xl),
                                  shadows: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.08,
                                      ),
                                      blurRadius: 40,
                                      offset: const Offset(0, 20),
                                    ),
                                  ],
                                  child: _buildForm(auth),
                                ),
                                const SizedBox(height: Insets.xl),
                                _buildOAuth(auth),
                                const SizedBox(height: Insets.xl),
                                _ServerChip(onTap: _openServerSettings),
                              ]
                              .animate(interval: 70.ms)
                              .fadeIn(duration: 450.ms)
                              .slideY(begin: 0.08, curve: Curves.easeOutCubic),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: Insets.sm,
                right: Insets.lg,
                child: GlassSurface(
                  borderRadius: BorderRadius.circular(99),
                  child: IconButton(
                    tooltip: 'Appearance',
                    icon: Icon(
                      Icons.palette_outlined,
                      color: context.colors.primary,
                    ),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AppearanceSettings(),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForm(AuthState auth) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ModeSwitch(isRegister: _isRegister, onChanged: _setMode),
          const SizedBox(height: Insets.xl),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            child: auth.errorMessage == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(bottom: Insets.lg),
                    child: _ErrorBanner(message: auth.errorMessage!),
                  ),
          ),
          TextFormField(
            controller: _usernameController,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                _isRegister ? RegExp(r'[a-zA-Z0-9]') : RegExp(r'[a-zA-Z0-9.]'),
              ),
            ],
            decoration: InputDecoration(
              labelText: 'Username',
              hintText: _isRegister ? 'letters and numbers' : 'e.g. alex.4821',
              prefixIcon: const Icon(Icons.alternate_email_rounded),
              helperText: _isRegister
                  ? 'A 4-digit tag is added for you, e.g. alex.4821'
                  : null,
              helperMaxLines: 2,
            ),
            validator: (v) =>
                AuthState.validateUsername(v, isRegister: _isRegister),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            child: _isRegister
                ? Padding(
                    padding: const EdgeInsets.only(top: Insets.lg),
                    child: TextFormField(
                      controller: _displayNameController,
                      textInputAction: TextInputAction.next,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                        hintText: 'How others see you',
                        prefixIcon: Icon(Icons.badge_outlined),
                        counterText: '',
                      ),
                      validator: AuthState.validateDisplayName,
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: Insets.lg),
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              helperText: _isRegister
                  ? 'At least ${ServerLimits.passwordMin} characters'
                  : null,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            validator: (v) =>
                AuthState.validatePassword(v, isRegister: _isRegister),
          ),
          const SizedBox(height: Insets.xl),
          GradientButton(
            label: _isRegister ? 'Create account' : 'Sign in',
            isLoading: auth.isLoading,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }

  Widget _buildOAuth(AuthState auth) {
    return Column(
      children: [
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.md),
              child: Text(
                'or continue with',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
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

class _Brand extends StatelessWidget {
  final bool isRegister;

  const _Brand({required this.isRegister});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 84,
          height: 84,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: context.glass.glassStrongFill,
            border: Border.all(color: context.glass.glassBorder),
            boxShadow: [
              BoxShadow(
                color: context.colors.primary.withValues(alpha: 0.35),
                blurRadius: 40,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Image.asset('assets/launcher/elephant.png'),
        ),
        const SizedBox(height: Insets.lg),
        Text('Elephant', style: context.text.headlineMedium),
        const SizedBox(height: Insets.xs),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: Text(
            isRegister
                ? 'Create your account. Your keys stay on this device.'
                : 'Private conversations, end-to-end encrypted.',
            key: ValueKey(isRegister),
            textAlign: TextAlign.center,
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  final bool isRegister;
  final ValueChanged<bool> onChanged;

  const _ModeSwitch({required this.isRegister, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            alignment: isRegister
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              child: AccentGradientBox(
                borderRadius: BorderRadius.circular(99),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          Row(
            children: [
              _segment(context, 'Sign in', !isRegister, () => onChanged(false)),
              _segment(context, 'Register', isRegister, () => onChanged(true)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: selected
                  ? context.glass.onAccent
                  : context.colors.onSurfaceVariant,
            ),
            child: Text(label),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: error, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: error,
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
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
    return GlassSurface(
      borderRadius: BorderRadius.circular(Radii.md),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (glyph != null)
                  Text(
                    glyph!,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                      color: context.colors.onSurface,
                    ),
                  )
                else
                  Icon(icon, size: 20, color: context.colors.onSurface),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerChip extends StatelessWidget {
  final VoidCallback onTap;

  const _ServerChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GlassSurface(
        borderRadius: BorderRadius.circular(99),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.dns_outlined,
                    size: 16,
                    color: context.colors.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    Env.isDefaultServer
                        ? 'Elephant Cloud'
                        : '${Env.host}:${Env.port}',
                    style: context.text.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.tune_rounded,
                    size: 15,
                    color: context.colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
