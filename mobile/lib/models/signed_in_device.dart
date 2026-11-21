/// One device the person is signed in on, as the server lists it.
class SignedInDevice {
  final String id;

  /// What the app called the phone when it signed in. Empty if it never said.
  final String name;
  final DateTime startedAt;
  final DateTime lastUsedAt;

  /// True for the device that is asking.
  final bool isCurrent;

  const SignedInDevice({
    required this.id,
    required this.name,
    required this.startedAt,
    required this.lastUsedAt,
    required this.isCurrent,
  });

  /// Reads one entry of the server's list, or null if it isn't usable.
  static SignedInDevice? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final started = DateTime.tryParse('${json['started_at']}');
    final used = DateTime.tryParse('${json['last_used_at']}');
    if (id is! String || id.isEmpty || started == null || used == null) {
      return null;
    }
    final name = json['device_name'];
    return SignedInDevice(
      id: id,
      name: name is String ? name.trim() : '',
      startedAt: started.toLocal(),
      lastUsedAt: used.toLocal(),
      isCurrent: json['current'] == true,
    );
  }

  String get title => name.isEmpty ? 'Unknown device' : name;
}

/// How long ago a device was last used, in a few words. The server only learns
/// of use when the app renews its sign-in, which is every 15 minutes, so
/// anything within 20 minutes is "Active now".
String describeLastActive(DateTime lastUsed, DateTime now) {
  final ago = now.difference(lastUsed);
  if (ago < const Duration(minutes: 20)) return 'Active now';
  if (ago < const Duration(hours: 1)) return 'Active ${ago.inMinutes} min ago';
  if (ago < const Duration(days: 1)) {
    final h = ago.inHours;
    return 'Active $h ${h == 1 ? 'hour' : 'hours'} ago';
  }
  final d = ago.inDays;
  return d == 1 ? 'Active yesterday' : 'Active $d days ago';
}
