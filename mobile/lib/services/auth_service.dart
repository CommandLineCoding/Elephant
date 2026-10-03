import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/constants.dart';

/// Thrown when the server rejects the refresh token, i.e. the session is over.
class SessionExpiredException implements Exception {
  @override
  String toString() => 'SessionExpiredException';
}

class AuthService {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;

  AuthService._internal();

  /// Called when the refresh token is rejected. Set by [AuthState].
  static VoidCallback? onSessionExpired;

  String? _cachedAccessToken;
  String? _cachedRefreshToken;

  /// Refresh tokens rotate on every use, so concurrent refreshes would revoke
  /// each other. Every caller shares this single in-flight refresh.
  Future<void>? _refreshing;

  Future<void> initTokens() async {
    _cachedAccessToken = await _storage.read(key: "access_token");
    _cachedRefreshToken = await _storage.read(key: "refresh_token");
  }

  Future<String?> getToken() async => _cachedAccessToken;
  Future<String?> getRefreshToken() async => _cachedRefreshToken;

  /// Returns an access token that is valid for at least another 30 seconds,
  /// refreshing it first if needed. Falls back to the current token when the
  /// refresh fails for a network reason.
  Future<String?> getValidAccessToken() async {
    final token = _cachedAccessToken;
    if (token == null) return null;
    if (!_expiresWithin(token, const Duration(seconds: 30))) return token;

    try {
      await refreshTokens();
    } on SessionExpiredException {
      return null;
    } catch (e) {
      debugPrint("Proactive token refresh failed: $e");
    }
    return _cachedAccessToken;
  }

  Future<void> refreshTokens() {
    return _refreshing ??= _performRefresh().whenComplete(() {
      _refreshing = null;
    });
  }

  Future<void> _performRefresh() async {
    final refreshToken = _cachedRefreshToken;
    if (refreshToken == null) {
      onSessionExpired?.call();
      throw SessionExpiredException();
    }

    try {
      final res = await _dio.post(
        "${Env.httpBaseUrl}/auth/refresh",
        data: {"refresh_token": refreshToken},
      );
      final data = res.data;
      if (data is! Map || data["success"] != true) {
        throw Exception("Refresh failed");
      }
      await saveTokens(
        data["data"]["access_token"],
        data["data"]["refresh_token"],
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 400) {
        onSessionExpired?.call();
        throw SessionExpiredException();
      }
      rethrow;
    }
  }

  static bool _expiresWithin(String jwt, Duration margin) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return false;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final exp = payload['exp'];
      if (exp is! int) return false;
      final expiry = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
      return DateTime.now().add(margin).isAfter(expiry);
    } catch (_) {
      return false;
    }
  }

  Future<void> saveTokens(String accessToken, String refreshToken) async {
    _cachedAccessToken = accessToken;
    _cachedRefreshToken = refreshToken;
    await _storage.write(key: "access_token", value: accessToken);
    await _storage.write(key: "refresh_token", value: refreshToken);
  }

  Future<void> saveUserProfile(String userJson) async {
    await _storage.write(key: "cached_user_profile", value: userJson);
  }

  Future<String?> getCachedUserProfile() async {
    return await _storage.read(key: "cached_user_profile");
  }

  Future<void> logout() async {
    _cachedAccessToken = null;
    _cachedRefreshToken = null;
    await _storage.delete(key: "access_token");
    await _storage.delete(key: "refresh_token");
    await _storage.delete(key: "cached_user_profile");
  }

  Future<Response> login(String username, String password) async {
    return await _dio.post(
      "${Env.httpBaseUrl}/auth/login",
      data: {"username": username, "password": password},
    );
  }

  Future<Response> register(
    String username,
    String displayName,
    String password,
  ) async {
    return await _dio.post(
      "${Env.httpBaseUrl}/auth/register",
      data: {
        "username": username,
        "display_name": displayName,
        "password": password,
      },
    );
  }

  Future<Response> getCurrentUser(String token) async {
    return await _dio.get(
      '${Env.httpBaseUrl}/users/me',
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
  }
}
