import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/services/auth_service.dart';
import 'package:mobile/services/push/push_notifier.dart';
import 'package:mobile/services/push/push_prefs.dart';
import 'package:unifiedpush/unifiedpush.dart';

enum PushStatus {
  /// Notifications are off.
  off,

  /// Waiting for the distributor to hand out an endpoint.
  registering,

  /// The server has our endpoint.
  active,

  /// Something went wrong; see [PushService.problem].
  failed,
}

enum PushEnableResult { ok, permissionDenied, noDistributor, cancelled }

/// A readable name for a distributor's package name.
String distributorLabel(String packageName) {
  const known = {
    'io.heckel.ntfy': 'ntfy',
    'org.unifiedpush.distributor.nextpush': 'NextPush',
    'org.unifiedpush.distributor.sunup': 'Sunup',
    'org.unifiedpush.distributor.gotify': 'Gotify-UP',
    'org.unifiedpush.distributor.fcm': 'Embedded FCM',
  };
  return known[packageName] ?? packageName;
}

/// New-message notifications through UnifiedPush.
///
/// The user picks a distributor app (ntfy, for example). It gives Elephant an
/// endpoint, which we hand to the Elephant server. When a message arrives for
/// someone with no live connection, the server pings that endpoint. The ping
/// carries no message content: it only wakes the app, which asks the server
/// what's unread and shows a generic "New message" notification.
///
/// A ping can arrive while the app isn't running. The UnifiedPush plugin then
/// starts the app in the background with [backgroundArg], and `main` calls
/// [init] without showing any UI.
class PushService with WidgetsBindingObserver {
  PushService._();
  static final PushService instance = PushService._();

  static const backgroundArg = '--unifiedpush-bg';
  static const _instance = 'elephant';

  final PushNotifier _notifier = PushNotifier();

  /// What the settings screen shows.
  final ValueNotifier<PushStatus> status = ValueNotifier(PushStatus.off);
  String? problem;

  /// Set when a notification is tapped; the home page opens that chat.
  final ValueNotifier<String?> chatToOpen = ValueNotifier(null);

  bool _background = false;
  bool _checking = false;

  Future<void> init(List<String> args) async {
    _background = args.contains(backgroundArg);

    await _notifier.init(onTap: _onNotificationTap);
    await UnifiedPush.initialize(
      onNewEndpoint: _onNewEndpoint,
      onRegistrationFailed: _onRegistrationFailed,
      onUnregistered: _onUnregistered,
      onMessage: _onMessage,
    );

    if (_background) return;

    WidgetsBinding.instance.addObserver(this);
    final launchedFrom = await _notifier.launchChatId();
    if (launchedFrom != null) chatToOpen.value = launchedFrom;
    unawaited(_restoreRegistration());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Opening the app clears its notifications.
    if (state == AppLifecycleState.resumed) unawaited(_notifier.cancelAll());
  }

  // --- Settings ---

  Future<bool> get isEnabled => PushPrefs.isEnabled();

  Future<bool> get permissionGranted => _notifier.permissionGranted();

  /// Installed distributor apps (their package names).
  Future<List<String>> distributors() => UnifiedPush.getDistributors();

  String? _lastDistributor;

  /// The distributor in use, if one was chosen. The plugin only reports it once
  /// registration has finished, so fall back to the one picked in [enable].
  Future<String?> currentDistributor() async =>
      await UnifiedPush.getDistributor() ?? _lastDistributor;

  /// Switches notifications on. [choose] picks one when several distributors
  /// are installed.
  Future<PushEnableResult> enable({
    required Future<String?> Function(List<String> distributors) choose,
  }) async {
    if (!await _notifier.requestPermission()) {
      return PushEnableResult.permissionDenied;
    }

    final installed = await UnifiedPush.getDistributors();
    if (installed.isEmpty) return PushEnableResult.noDistributor;

    var distributor = await UnifiedPush.getDistributor();
    if (distributor == null || !installed.contains(distributor)) {
      distributor = installed.length == 1
          ? installed.first
          : await choose(installed);
      if (distributor == null) return PushEnableResult.cancelled;
      await UnifiedPush.saveDistributor(distributor);
    }
    _lastDistributor = distributor;

    problem = null;
    await PushPrefs.setEnabled(true);
    await PushPrefs.clearLastNotified();
    status.value = PushStatus.registering;
    await UnifiedPush.register(instance: _instance);
    return PushEnableResult.ok;
  }

  Future<void> disable() async {
    await PushPrefs.setEnabled(false);
    await _removeFromServer();
    try {
      await UnifiedPush.unregister(_instance);
    } catch (e) {
      debugPrint('UnifiedPush unregister failed: $e');
    }
    problem = null;
    status.value = PushStatus.off;
  }

  // --- Account changes ---

  /// After signing in, give the new account the device's endpoint.
  Future<void> onSignedIn() => _restoreRegistration();

  /// Before the token is dropped on sign-out: stop pings for this account.
  /// The distributor registration stays, so signing in again is instant.
  Future<void> onSigningOut() async {
    await _removeFromServer();
    await PushPrefs.clearLastNotified();
  }

  // --- UnifiedPush callbacks ---

  Future<void> _restoreRegistration() async {
    if (!await PushPrefs.isEnabled()) return;
    if (await AuthService().getToken() == null) return;
    if (await UnifiedPush.getDistributor() == null) return;
    status.value = PushStatus.registering;
    // Registering again gives us the current endpoint, which we re-send, so
    // the server has it even if it lost it.
    await UnifiedPush.register(instance: _instance);
  }

  Future<void> _onNewEndpoint(PushEndpoint endpoint, String instance) async {
    await PushPrefs.setEndpoint(endpoint.url);
    if (await AuthService().getToken() == null) return;
    try {
      await ApiService().registerPushEndpoint(endpoint.url);
      problem = null;
      status.value = PushStatus.active;
    } catch (e) {
      debugPrint('Could not give the server the push endpoint: $e');
      problem = ApiService.errorMessage(
        e,
        fallback: "Couldn't register for notifications with the server.",
      );
      status.value = PushStatus.failed;
    }
  }

  void _onRegistrationFailed(FailedReason reason, String instance) {
    problem = switch (reason) {
      FailedReason.network => 'No network. Try again later.',
      FailedReason.actionRequired =>
        'Open your distributor app and finish setting it up.',
      FailedReason.vapidRequired =>
        "This distributor requires a feature Elephant doesn't support yet. "
            'Try another one, such as ntfy.',
      FailedReason.internalError => 'The distributor reported an error.',
    };
    status.value = PushStatus.failed;
  }

  void _onUnregistered(String instance) {
    // The distributor dropped us (it was uninstalled, or the user removed us).
    unawaited(PushPrefs.setEnabled(false));
    unawaited(_removeFromServer());
    status.value = PushStatus.off;
  }

  /// A ping: the server has something for us.
  Future<void> _onMessage(PushMessage message, String instance) async {
    // The ping's content is not used, whether or not it decrypted.
    if (_checking) return;

    // When the app is open it is connected live and shows messages itself.
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }

    _checking = true;
    try {
      await _notifyAboutUnread();
    } catch (e) {
      debugPrint('Could not check for new messages: $e');
    } finally {
      _checking = false;
    }
  }

  Future<void> _notifyAboutUnread() async {
    if (!await PushPrefs.isEnabled()) return;

    final response = await ApiService().getConversations();
    final conversations = ApiService.dataList(response.data)
        .map(
          (json) => InboxItem.fromConversationJson(
            Map<String, dynamic>.from(json as Map),
            lastMessage: '',
          ),
        )
        .toList();

    final lastNotified = await PushPrefs.lastNotified();
    final due = chatsToNotify(
      conversations,
      lastNotified,
      since: await PushPrefs.enabledAt(),
    );
    if (due.isEmpty) return;

    final showName = await PushPrefs.showNames();
    for (final chat in due) {
      await _notifier.showChat(chat, showName: showName);
      lastNotified[chat.id] = chat.timestamp.millisecondsSinceEpoch;
    }
    await PushPrefs.setLastNotified(lastNotified);
  }

  void _onNotificationTap(NotificationResponse response) {
    final id = chatIdFromPayload(response.payload);
    if (id != null) chatToOpen.value = id;
  }

  Future<void> _removeFromServer() async {
    final endpoint = await PushPrefs.endpoint();
    if (endpoint == null) return;
    try {
      // Short timeout: this runs on sign-out, which shouldn't wait for a
      // server that can't be reached.
      await ApiService()
          .removePushEndpoint(endpoint)
          .timeout(const Duration(seconds: 3));
      await PushPrefs.setEndpoint(null);
    } catch (e) {
      // Best effort: the server drops endpoints the distributor reports as gone.
      debugPrint('Could not remove the push endpoint from the server: $e');
    }
  }
}
