import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/services/db_services.dart';
import 'package:mobile/services/signal_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:app_links/app_links.dart';
import 'package:mobile/models/user.dart';
import '../core/constants.dart';
import '../services/auth_service.dart';

class AuthState extends ChangeNotifier {
  final AuthService _authService = AuthService();
  final AppLinks _appLinks = AppLinks();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  StreamSubscription<Uri>? _linkSubscription;

  String? _token;
  bool _isLoading = false;
  String? _errorMessage;
  UserModel? _currentUser;

  /// Full username (with discriminator) assigned at registration, shown once
  /// so the user knows what to log in with.
  String? newlyRegisteredUsername;

  String? get token => _token;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  UserModel? get currentUser => _currentUser;

  AuthState() {
    AuthService.onSessionExpired = logoutSilently;
    _initDeepLinks();
  }

  // --- Validation (mirrors the server's rules) ---

  static String? validateUsername(String? value, {required bool isRegister}) {
    final text = (value ?? '').trim().toLowerCase();
    if (text.isEmpty) return 'Enter your username';
    if (!isRegister) return null;
    if (text.length < ServerLimits.usernameMin ||
        text.length > ServerLimits.usernameMax) {
      return 'Use ${ServerLimits.usernameMin}–${ServerLimits.usernameMax} characters';
    }
    if (!RegExp(r'^[a-z0-9]+$').hasMatch(text)) {
      return 'Only letters and numbers';
    }
    return null;
  }

  static String? validatePassword(String? value, {required bool isRegister}) {
    final text = value ?? '';
    if (text.isEmpty) return 'Enter your password';
    if (isRegister && text.length < ServerLimits.passwordMin) {
      return 'Use at least ${ServerLimits.passwordMin} characters';
    }
    return null;
  }

  static String? validateDisplayName(String? value) {
    return (value ?? '').trim().isEmpty ? 'Enter a display name' : null;
  }

  void clearError() {
    if (_errorMessage != null) {
      _errorMessage = null;
      notifyListeners();
    }
  }

  // --- Deep links (OAuth handoff) ---

  Future<void> _initDeepLinks() async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) _handleIncomingUri(initialUri);
    } catch (e) {
      debugPrint("Error reading initial deep link: $e");
    }

    _linkSubscription = _appLinks.uriLinkStream.listen(
      _handleIncomingUri,
      onError: (err) => debugPrint("Deep link stream error: $err"),
    );
  }

  void _handleIncomingUri(Uri uri) {
    if (uri.scheme == 'elephant' && uri.host == 'oauth-callback') {
      handleOAuthCallback(uri);
    }
  }

  // --- Session ---

  Future<void> loadUserProfile() async {
    if (_token == null) return;

    try {
      final res = await ApiService().getMe();
      final userData = ApiService.dataMap(res.data);
      _currentUser = UserModel.fromJson(userData);
      await _authService.saveUserProfile(jsonEncode(userData));
    } catch (e) {
      debugPrint("Profile fetch failed, using cached profile: $e");
      final cachedData = await _authService.getCachedUserProfile();
      if (cachedData != null) {
        _currentUser = UserModel.fromJson(jsonDecode(cachedData));
      }
    }
    notifyListeners();
  }

  Future<String?> checkAutoLogin() async {
    _token = await _authService.getToken();

    if (_token != null) {
      await loadUserProfile();
      if (_currentUser != null) {
        unawaited(SignalService().ensureKeysPublished());
      }
    }

    notifyListeners();
    return _token;
  }

  /// Stores the token pair, loads the profile and publishes E2EE keys.
  Future<bool> _completeSignIn(String accessToken, String refreshToken) async {
    await _authService.saveTokens(accessToken, refreshToken);
    _token = accessToken;
    await loadUserProfile();

    if (_currentUser == null) {
      _errorMessage = "Signed in, but your profile couldn't be loaded.";
      _token = null;
      await _authService.logout();
      return false;
    }

    // Keys on this device belong to whoever signed in last.
    final lastUserId = await _storage.read(key: "last_user_id");
    if (lastUserId != null && lastUserId != _currentUser!.id) {
      await SignalService().wipeLocalKeys();
      await DatabaseHelper.instance.wipeChatData();
    }
    await _storage.write(key: "last_user_id", value: _currentUser!.id);

    await SignalService().ensureKeysPublished();
    return true;
  }

  Future<bool> _runAuthRequest(
    Future<Response> Function() request,
    String fallbackError,
  ) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    bool success = false;
    try {
      final res = await request();
      final data = ApiService.dataMap(res.data);
      final tokens = data['tokens'];
      if (tokens is Map &&
          tokens['access_token'] != null &&
          tokens['refresh_token'] != null) {
        final user = data['user'];
        if (user is Map) {
          newlyRegisteredUsername = res.statusCode == 201
              ? user['username']?.toString()
              : null;
        }
        success = await _completeSignIn(
          tokens['access_token'],
          tokens['refresh_token'],
        );
      } else {
        _errorMessage = fallbackError;
      }
    } catch (e) {
      _errorMessage = ApiService.errorMessage(e, fallback: fallbackError);
    }

    _isLoading = false;
    notifyListeners();
    return success;
  }

  Future<bool> handleLogin(String username, String password) {
    return _runAuthRequest(
      () => _authService.login(username.trim().toLowerCase(), password),
      "Couldn't sign you in",
    );
  }

  Future<bool> handleRegister(
    String username,
    String displayName,
    String password,
  ) {
    return _runAuthRequest(
      () => _authService.register(
        username.trim().toLowerCase(),
        displayName.trim(),
        password,
      ),
      "Couldn't create your account",
    );
  }

  Future<void> handleOAuthLogin(String provider) async {
    _errorMessage = null;
    notifyListeners();

    try {
      final launched = await launchUrl(
        Uri.parse("${Env.httpBaseUrl}/auth/$provider"),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        _errorMessage = "Couldn't open the browser for $provider sign-in.";
        notifyListeners();
      }
    } catch (e) {
      _errorMessage = "Couldn't start $provider sign-in.";
      notifyListeners();
    }
  }

  Future<bool> handleOAuthCallback(Uri uri) async {
    final accessToken = uri.queryParameters['access_token'];
    final refreshToken = uri.queryParameters['refresh_token'];

    if (accessToken == null || refreshToken == null) {
      _errorMessage =
          uri.queryParameters['error'] ?? "Sign-in was cancelled or failed.";
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    final success = await _completeSignIn(accessToken, refreshToken);

    _isLoading = false;
    notifyListeners();
    return success;
  }

  Future<void> logout() async {
    _token = null;
    _currentUser = null;
    await _authService.logout();
    notifyListeners();
  }

  void logoutSilently() {
    if (_token != null) {
      _token = null;
      _currentUser = null;
      _errorMessage = "Your session expired. Please sign in again.";
      _authService.logout();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }
}
