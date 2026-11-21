/// The longest "about" text and custom status text, in characters. The server
/// checks them too.
const profileBioMax = 140;
const profileStatusMax = 60;

/// How long a custom status lasts.
enum StatusDuration {
  never('Until I change it', null),
  hour('1 hour', Duration(hours: 1)),
  fourHours('4 hours', Duration(hours: 4)),
  today('Today', null),
  week('1 week', Duration(days: 7));

  final String label;
  final Duration? fixed;
  const StatusDuration(this.label, this.fixed);

  /// How long from [now] until this ends, or null for no end. "Today" ends at
  /// the next midnight, and is at least a minute so the server accepts it.
  Duration? from(DateTime now) {
    if (this == StatusDuration.never) return null;
    if (this == StatusDuration.today) {
      final midnight = DateTime(now.year, now.month, now.day + 1);
      final left = midnight.difference(now);
      return left < const Duration(minutes: 1)
          ? const Duration(minutes: 1)
          : left;
    }
    return fixed;
  }
}
