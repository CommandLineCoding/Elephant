import 'api_services.dart';

/// Whether two-step sign-in is on, and how many recovery codes are left.
class TwoFactorStatus {
  final bool enabled;
  final int recoveryCodesLeft;

  const TwoFactorStatus({this.enabled = false, this.recoveryCodesLeft = 0});

  factory TwoFactorStatus.fromJson(Map<String, dynamic> json) =>
      TwoFactorStatus(
        enabled: json['enabled'] == true,
        recoveryCodesLeft: json['recovery_codes_left'] is int
            ? json['recovery_codes_left'] as int
            : 0,
      );
}

/// What setup gives to show: the secret as text, and the address that goes in
/// the QR code for an authenticator app.
class TwoFactorSetup {
  final String secret;
  final String uri;

  const TwoFactorSetup({required this.secret, required this.uri});

  /// The secret in groups of four, easier to read and type.
  String get spacedSecret => [
    for (var i = 0; i < secret.length; i += 4)
      secret.substring(i, i + 4 > secret.length ? secret.length : i + 4),
  ].join(' ');
}

/// The server calls behind two-step sign-in. A class so a test can stand in
/// for the server.
abstract class TwoFactorApi {
  Future<TwoFactorStatus> status();
  Future<TwoFactorSetup> start();
  Future<List<String>> enable(String code);
  Future<void> disable(String password, String code);
}

class ServerTwoFactorApi implements TwoFactorApi {
  const ServerTwoFactorApi();

  @override
  Future<TwoFactorStatus> status() async => TwoFactorStatus.fromJson(
    ApiService.dataMap((await ApiService().getTwoFactor()).data),
  );

  @override
  Future<TwoFactorSetup> start() async {
    final d = ApiService.dataMap((await ApiService().startTwoFactor()).data);
    return TwoFactorSetup(
      secret: '${d['secret'] ?? ''}',
      uri: '${d['otpauth_uri'] ?? ''}',
    );
  }

  @override
  Future<List<String>> enable(String code) async {
    final d = ApiService.dataMap(
      (await ApiService().enableTwoFactor(code)).data,
    );
    return [for (final c in (d['recovery_codes'] as List? ?? [])) '$c'];
  }

  @override
  Future<void> disable(String password, String code) async {
    await ApiService().disableTwoFactor(password, code);
  }
}
