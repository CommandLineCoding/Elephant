import 'dart:convert';

/// Someone on a broadcast list.
class BroadcastMember {
  final String id;
  final String name;

  const BroadcastMember({required this.id, required this.name});

  Map<String, String> toJson() => {'id': id, 'name': name};
}

/// A list of people a message can be sent to one by one. Only on this phone:
/// nobody, the server included, learns that the list exists.
class BroadcastList {
  final String id;
  final String name;
  final List<BroadcastMember> members;

  const BroadcastList({
    required this.id,
    required this.name,
    this.members = const [],
  });

  BroadcastList copyWith({String? name, List<BroadcastMember>? members}) =>
      BroadcastList(
        id: id,
        name: name ?? this.name,
        members: members ?? this.members,
      );

  /// [members] as stored: a JSON list.
  static String encodeMembers(List<BroadcastMember> members) =>
      jsonEncode([for (final m in members) m.toJson()]);

  /// The members stored by [encodeMembers]. Anything unreadable is skipped, so
  /// a damaged row gives a shorter list rather than an error.
  static List<BroadcastMember> decodeMembers(String json) {
    try {
      return [
        for (final item in jsonDecode(json) as List)
          if (item is Map && item['id'] is String)
            BroadcastMember(
              id: item['id'] as String,
              name: (item['name'] as String?) ?? '',
            ),
      ];
    } catch (_) {
      return [];
    }
  }
}
