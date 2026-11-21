import 'package:dio/dio.dart';
import '../core/constants.dart';
import 'auth_service.dart';

/// A call ringing for us while the app wasn't connected.
class PendingCall {
  final String id;
  final String callerId;
  final String callerName;

  const PendingCall({
    required this.id,
    required this.callerId,
    required this.callerName,
  });

  /// Reads `GET /api/calls/pending`; null when nothing is ringing.
  static PendingCall? fromResponse(dynamic body) {
    if (body is! Map || body['data'] is! Map) return null;
    final data = body['data'] as Map;
    final id = data['call_id']?.toString() ?? '';
    final caller = data['caller_id']?.toString() ?? '';
    if (id.isEmpty || caller.isEmpty) return null;
    return PendingCall(
      id: id,
      callerId: caller,
      callerName: data['caller_display_name']?.toString() ?? '',
    );
  }
}

/// HTTP client for the Elephant REST API (see docs/API_CONTRACTS.md).
class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );
  final AuthService _auth = AuthService();

  ApiService._internal() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          options.baseUrl = Env.httpBaseUrl;
          final token = await _auth.getValidAccessToken();
          if (token != null) {
            options.headers["Authorization"] = "Bearer $token";
          }
          return handler.next(options);
        },
        onError: (DioException e, handler) async {
          final alreadyRetried = e.requestOptions.extra['retried'] == true;
          if (e.response?.statusCode != 401 || alreadyRetried) {
            return handler.next(e);
          }

          try {
            await _auth.refreshTokens();
            final retryOptions = e.requestOptions
              ..extra['retried'] = true
              ..headers["Authorization"] = "Bearer ${await _auth.getToken()}";
            return handler.resolve(await _dio.fetch(retryOptions));
          } on DioException catch (retryError) {
            return handler.next(retryError);
          } catch (_) {
            return handler.next(e);
          }
        },
      ),
    );
  }

  /// Human-readable message for a failed request, preferring the server's
  /// `error` field.
  static String errorMessage(
    Object error, {
    String fallback = 'Something went wrong',
  }) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 429) return 'Too many requests. Please slow down.';
      final data = error.response?.data;
      if (data is Map &&
          data['error'] is String &&
          (data['error'] as String).isNotEmpty) {
        final message = data['error'] as String;
        return message[0].toUpperCase() + message.substring(1);
      }
      // A bare 404/405 (not our JSON envelope) means the route doesn't exist,
      // i.e. the server is older than the app.
      if ((status == 404 || status == 405) && data is! Map) {
        return 'This server doesn\'t support that yet. It may need updating.';
      }
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return 'The server took too long to respond.';
        case DioExceptionType.connectionError:
          return 'Can\'t reach the server. Check your connection.';
        default:
          break;
      }
    }
    return fallback;
  }

  /// Unwraps `{"success": true, "data": [...]}` into a list.
  static List<dynamic> dataList(dynamic body) {
    if (body is List) return body;
    if (body is Map && body['data'] is List) return body['data'];
    return [];
  }

  /// Unwraps `{"success": true, "data": {...}}` into a map.
  static Map<String, dynamic> dataMap(dynamic body) {
    if (body is Map && body['data'] is Map) {
      return Map<String, dynamic>.from(body['data']);
    }
    if (body is Map) return Map<String, dynamic>.from(body);
    return {};
  }

  // --- Users ---

  Future<Response> getMe() => _dio.get("/users/me");

  Future<Response> deleteAccount() => _dio.delete("/users/me");

  /// Deletes a direct conversation for you, or with [forEveryone] also the
  /// messages you sent in it, for both people.
  Future<Response> deleteConversation(
    String userId, {
    required bool forEveryone,
  }) => _dio.delete(
    "/messages/conversations/$userId",
    queryParameters: {'for': forEveryone ? 'everyone' : 'me'},
  );

  Future<Response> blockUser(String userId) =>
      _dio.post("/users/$userId/block");

  Future<Response> unblockUser(String userId) =>
      _dio.delete("/users/$userId/block");

  Future<Response> listBlockedUsers() => _dio.get("/users/me/blocked");

  /// Deletes one message. For [forEveryone] it must be ours, and it becomes
  /// "This message was deleted" for everyone; otherwise it's only removed from
  /// our own view.
  Future<Response> deleteMessage(
    String messageId, {
    required bool forEveryone,
  }) => _dio.delete(
    "/messages/$messageId",
    queryParameters: {"for": forEveryone ? "everyone" : "me"},
  );

  /// The call ringing for us, if any (asked when a push wakes the app). Null
  /// when nothing is ringing, or the server doesn't support it.
  Future<PendingCall?> pendingCall() async {
    try {
      final response = await _dio.get("/calls/pending");
      return PendingCall.fromResponse(response.data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// STUN/TURN servers for a call, or null if the server doesn't support
  /// calls (it answers 404).
  Future<List<Map<String, dynamic>>?> iceServers() async {
    try {
      final response = await _dio.get("/calls/ice-servers");
      final servers = dataMap(response.data)['ice_servers'];
      return [
        for (final s in (servers is List ? servers : const []))
          if (s is Map) Map<String, dynamic>.from(s),
      ];
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Clears a group's messages for you only.
  Future<Response> clearGroupHistory(String groupId) =>
      _dio.delete("/groups/$groupId/history");

  /// Deletes a group for everyone (admins only).
  Future<Response> deleteGroup(String groupId) =>
      _dio.delete("/groups/$groupId");
  Future<Response> updateMe({required String displayName}) =>
      _dio.patch("/users/me", data: {"display_name": displayName});

  // --- Reports ---

  Future<Response> createReport(Map<String, dynamic> report) =>
      _dio.post("/reports", data: report);

  // --- Privacy settings ---

  Future<Response> getSettings() => _dio.get("/users/me/settings");

  Future<Response> updateSettings(Map<String, dynamic> change) =>
      _dio.patch("/users/me/settings", data: change);

  // --- Signed-in devices ---

  Future<Response> getSessions() => _dio.get("/users/me/sessions");

  Future<Response> signOutSession(String id) =>
      _dio.delete("/users/me/sessions/$id");

  Future<Response> signOutOtherSessions() => _dio.delete("/users/me/sessions");

  // --- Push notifications (UnifiedPush) ---

  Future<Response> registerPushEndpoint(String endpoint) =>
      _dio.post("/users/me/push", data: {"endpoint": endpoint});

  Future<Response> removePushEndpoint(String endpoint) =>
      _dio.delete("/users/me/push", data: {"endpoint": endpoint});

  Future<Response> getUser(String userId) => _dio.get("/users/$userId");

  Future<Response> searchUsers(String query, {int page = 1}) {
    return _dio.get(
      "/users/search",
      queryParameters: {
        "q": query,
        "page": page,
        "limit": ServerLimits.searchPageSize,
      },
    );
  }

  // --- Messages ---

  Future<Response> getConversations() => _dio.get("/messages/conversations");

  Future<Response> getChatHistory(
    String targetId, {
    String? before,
    bool isGroup = false,
  }) {
    final Map<String, dynamic> params = {"limit": ServerLimits.historyPageSize};
    if (before != null) params["before"] = before;

    if (isGroup) {
      return _dio.get("/groups/$targetId/messages", queryParameters: params);
    }
    params["with"] = targetId;
    return _dio.get("/messages", queryParameters: params);
  }

  Future<Response> editMessage(String messageId, String content) {
    return _dio.put("/messages/$messageId", data: {"content": content});
  }

  Future<Response> markDirectRead(String senderId) {
    return _dio.post("/messages/read", data: {"sender_id": senderId});
  }

  // --- Groups ---

  Future<Response> getGroups() => _dio.get("/groups");

  Future<Response> getGroup(String groupId) => _dio.get("/groups/$groupId");

  Future<Response> createGroup(String name) {
    return _dio.post("/groups", data: {"name": name});
  }

  Future<Response> renameGroup(String groupId, String name) {
    return _dio.patch("/groups/$groupId", data: {"name": name});
  }

  Future<Response> getGroupMembers(String groupId) {
    return _dio.get("/groups/$groupId/members");
  }

  Future<Response> addGroupMember(String groupId, String userId) {
    return _dio.post("/groups/$groupId/members", data: {"user_id": userId});
  }

  Future<Response> removeGroupMember(String groupId, String userId) {
    return _dio.delete("/groups/$groupId/members/$userId");
  }

  Future<Response> leaveGroup(String groupId) {
    return _dio.post("/groups/$groupId/leave");
  }

  // --- E2EE ---

  Future<Response> uploadPrekeys(Map<String, dynamic> bundle) {
    return _dio.post("/e2ee/keys", data: bundle);
  }

  Future<Response> getPrekeyBundle(String userId, {String deviceId = 'main'}) {
    return _dio.get(
      "/e2ee/bundle/$userId",
      queryParameters: {"device_id": deviceId},
    );
  }

  Future<Response> getVerification(String userId) {
    return _dio.get("/e2ee/verify/$userId");
  }

  Future<Response> setVerification(String userId, bool isVerified) {
    return _dio.post(
      "/e2ee/verify",
      data: {"verified_user_id": userId, "is_verified": isVerified},
    );
  }

  Future<Response> resetEncryptionKeys(String password) {
    return _dio.post("/e2ee/reset", data: {"password": password});
  }
}
