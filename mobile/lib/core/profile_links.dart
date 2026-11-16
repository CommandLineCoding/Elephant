import 'package:flutter/foundation.dart';
import 'package:mobile/core/constants.dart';

/// Profile links open a chat with someone:
/// `https://elephant.commandlinecoding.in/u/<username>` (opens the app
/// directly once Android has verified it) or `elephant://u/<username>`.
///
/// Android only opens https links for a host fixed in the app, so people on a
/// self-hosted server share the `elephant://` form.
class ProfileLinks {
  ProfileLinks._();

  static final ProfileLinks instance = ProfileLinks._();

  static const webHost = 'elephant.commandlinecoding.in';
  static final _username = RegExp(r'^[a-z0-9]{1,40}\.[0-9]{4}$');

  /// A username from an opened link, waiting until someone is signed in and
  /// the home screen can open the chat.
  final ValueNotifier<String?> pending = ValueNotifier(null);

  /// The username a profile link points to, or null if it isn't one.
  static String? usernameFrom(Uri uri) {
    String? name;
    if (uri.scheme == 'elephant' && uri.host == 'u') {
      name = uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
    } else if (uri.scheme == 'https' &&
        uri.host == webHost &&
        uri.pathSegments.length == 2 &&
        uri.pathSegments.first == 'u') {
      name = uri.pathSegments[1];
    }
    name = name?.toLowerCase();
    return name != null && _username.hasMatch(name) ? name : null;
  }

  /// The link to share for [username] on the server the app uses.
  static Uri linkFor(String username) => Env.isDefaultServer
      ? Uri.https(webHost, '/u/$username')
      : Uri(scheme: 'elephant', host: 'u', path: '/$username');

  /// Handles an opened link. Returns false if it isn't a profile link.
  bool open(Uri uri) {
    final name = usernameFrom(uri);
    if (name == null) return false;
    pending.value = name;
    return true;
  }
}
