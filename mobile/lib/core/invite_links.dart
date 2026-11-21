import 'package:flutter/foundation.dart';
import 'package:mobile/core/constants.dart';
import 'package:mobile/core/profile_links.dart';

/// Group invite links: `https://elephant.commandlinecoding.in/g/<code>` (opens
/// the app directly once Android has verified it) or `elephant://g/<code>`.
/// The code is 32 random characters and the only secret in the link.
class InviteLinks {
  InviteLinks._();

  static final InviteLinks instance = InviteLinks._();

  static final _code = RegExp(r'^[A-Za-z0-9_-]{32}$');

  /// A code from an opened link, waiting until someone is signed in and the
  /// home screen can show the invitation.
  final ValueNotifier<String?> pending = ValueNotifier(null);

  /// The code an invite link points to, or null if it isn't one.
  static String? codeFrom(Uri uri) {
    String? code;
    if (uri.scheme == 'elephant' && uri.host == 'g') {
      code = uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
    } else if (uri.scheme == 'https' &&
        uri.host == ProfileLinks.webHost &&
        uri.pathSegments.length == 2 &&
        uri.pathSegments.first == 'g') {
      code = uri.pathSegments[1];
    }
    return code != null && _code.hasMatch(code) ? code : null;
  }

  /// Whether [text] is a valid code.
  static bool isCode(String text) => _code.hasMatch(text);

  /// The link to share for [code] on the server the app uses.
  static Uri linkFor(String code) => Env.isDefaultServer
      ? Uri.https(ProfileLinks.webHost, '/g/$code')
      : Uri(scheme: 'elephant', host: 'g', path: '/$code');

  /// Handles an opened link. Returns false if it isn't an invite link.
  bool open(Uri uri) {
    final code = codeFrom(uri);
    if (code == null) return false;
    pending.value = code;
    return true;
  }
}
