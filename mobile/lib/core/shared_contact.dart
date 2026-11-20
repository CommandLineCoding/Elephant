import 'message_payload.dart';
import 'profile_links.dart';

/// Someone shared in a chat: enough to start a chat with them.
class SharedContact {
  final String id;
  final String name;
  final String username;

  const SharedContact({
    required this.id,
    required this.name,
    required this.username,
  });

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static final _username = RegExp(r'^[a-z0-9]{1,40}\.[0-9]{4}$');
  static const maxNameLength = 100;

  /// Reads a `contact` payload, or null if it isn't a usable one. The ID and
  /// username are checked, since they came from someone else.
  static SharedContact? fromPayload(MessagePayload? payload) {
    if (payload == null || payload.kind != 'contact') return null;
    final id = payload.field<String>('id');
    final username = payload.field<String>('username');
    final name = payload.field<String>('name')?.trim();
    if (id == null || !_uuid.hasMatch(id)) return null;
    if (username == null || !_username.hasMatch(username)) return null;
    if (name == null || name.isEmpty || name.length > maxNameLength) {
      return null;
    }
    return SharedContact(id: id, name: name, username: username);
  }

  /// The payload for this contact, and the text apps without shared contacts
  /// show: their name and a link that opens a chat with them.
  (Map<String, dynamic>, String) toPayload() => (
    {'id': id, 'name': name, 'username': username},
    '👤 Contact: $name (@$username)\n${ProfileLinks.linkFor(username)}',
  );
}
