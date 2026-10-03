import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/core/constants.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/glass.dart';

/// Lets the user point the app at a self-hosted Elephant server before
/// signing in. Returns once the sheet closes.
Future<void> showServerSettingsSheet(BuildContext context) {
  return showGlassSheet(
    context,
    title: 'Server',
    builder: (_) => const _ServerSettingsForm(),
  );
}

class _ServerSettingsForm extends StatefulWidget {
  const _ServerSettingsForm();

  @override
  State<_ServerSettingsForm> createState() => _ServerSettingsFormState();
}

enum _Health { unknown, checking, up, dbDown, unreachable }

class _ServerSettingsFormState extends State<_ServerSettingsForm> {
  late final TextEditingController _host = TextEditingController(
    text: Env.host,
  );
  late final TextEditingController _port = TextEditingController(
    text: Env.port,
  );
  _Health _health = _Health.unknown;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  String _baseUrl(String host, String port) {
    final secure = port == '443' || host.contains('commandlinecoding.in');
    final suffix = (port == '80' || port == '443') ? '' : ':$port';
    return '${secure ? 'https' : 'http'}://$host$suffix/api';
  }

  Future<void> _test() async {
    final host = _host.text.trim().isEmpty
        ? Env.defaultHost
        : _host.text.trim();
    final port = _port.text.trim().isEmpty
        ? Env.defaultPort
        : _port.text.trim();
    setState(() => _health = _Health.checking);
    try {
      final res = await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 6),
        ),
      ).get('${_baseUrl(host, port)}/health');
      final up = res.data is Map && res.data['data']?['postgres'] == 'up';
      setState(() => _health = up ? _Health.up : _Health.dbDown);
    } on DioException catch (e) {
      setState(
        () => _health = e.response?.statusCode == 500
            ? _Health.dbDown
            : _Health.unreachable,
      );
    } catch (_) {
      setState(() => _health = _Health.unreachable);
    }
  }

  Future<void> _save({bool reset = false}) async {
    final navigator = Navigator.of(context);
    await Env.updateConfig(reset ? '' : _host.text, reset ? '' : _port.text);
    navigator.pop();
    if (mounted) {
      showSnack(
        context,
        reset
            ? 'Using Elephant Cloud'
            : 'Server set to ${Env.host}:${Env.port}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.xl, Insets.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Connect to Elephant Cloud or your own self-hosted server.',
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.xl),
          TextField(
            controller: _host,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onChanged: (_) => setState(() => _health = _Health.unknown),
            decoration: const InputDecoration(
              labelText: 'Host',
              hintText: Env.defaultHost,
              prefixIcon: Icon(Icons.language_rounded),
            ),
          ),
          const SizedBox(height: Insets.md),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() => _health = _Health.unknown),
            decoration: const InputDecoration(
              labelText: 'Port',
              hintText: Env.defaultPort,
              prefixIcon: Icon(Icons.numbers_rounded),
              helperText:
                  'Port 443 uses HTTPS/WSS; other ports use plain HTTP/WS.',
            ),
          ),
          const SizedBox(height: Insets.lg),
          Row(
            children: [
              Expanded(child: _HealthIndicator(health: _health)),
              TextButton.icon(
                onPressed: _health == _Health.checking ? null : _test,
                icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
                label: const Text('Test'),
              ),
            ],
          ),
          const SizedBox(height: Insets.lg),
          GradientButton(label: 'Save', onPressed: _save),
          const SizedBox(height: Insets.sm),
          TextButton(
            onPressed: () => _save(reset: true),
            child: const Text('Use Elephant Cloud'),
          ),
        ],
      ),
    );
  }
}

class _HealthIndicator extends StatelessWidget {
  final _Health health;

  const _HealthIndicator({required this.health});

  @override
  Widget build(BuildContext context) {
    switch (health) {
      case _Health.unknown:
        return Text(
          'Not tested',
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        );
      case _Health.checking:
        return const Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case _Health.up:
        return Align(
          alignment: Alignment.centerLeft,
          child: TagPill(
            'Server is healthy',
            color: context.glass.success,
            icon: Icons.check_rounded,
          ),
        );
      case _Health.dbDown:
        return Align(
          alignment: Alignment.centerLeft,
          child: TagPill(
            'Database unreachable',
            color: context.glass.warning,
            icon: Icons.warning_amber_rounded,
          ),
        );
      case _Health.unreachable:
        return Align(
          alignment: Alignment.centerLeft,
          child: TagPill(
            'Can\'t reach server',
            color: context.colors.error,
            icon: Icons.close_rounded,
          ),
        );
    }
  }
}
