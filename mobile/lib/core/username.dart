/// Rules for the part of a username a person chooses (the part before the
/// dot), the same as when signing up. The server checks them again.
const usernamePrefixMin = 3;
const usernamePrefixMax = 25;

/// How long someone waits between username changes.
const usernameChangeInterval = Duration(days: 30);

final _prefixCharacters = RegExp(r'^[a-z0-9]+$');

/// Why [input] can't be used, or null if it can.
String? usernamePrefixProblem(String input) {
  final prefix = input.trim().toLowerCase();
  if (prefix.length < usernamePrefixMin || prefix.length > usernamePrefixMax) {
    return 'Use $usernamePrefixMin to $usernamePrefixMax letters and numbers.';
  }
  if (!_prefixCharacters.hasMatch(prefix)) {
    return 'Use only letters and numbers, with no spaces.';
  }
  return null;
}

/// The part of a username before the dot: `alex` for `alex.4821`.
String usernamePrefix(String username) {
  final dot = username.lastIndexOf('.');
  return dot <= 0 ? username : username.substring(0, dot);
}

/// When the username can next be changed, or null if it can be now.
DateTime? nextUsernameChange(DateTime? changedAt, DateTime now) {
  if (changedAt == null) return null;
  final next = changedAt.add(usernameChangeInterval);
  return next.isAfter(now) ? next : null;
}
