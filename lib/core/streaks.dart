import 'services/event_window.dart';

/// The two streaks, read the way the server writes them
/// (functions/voteStreak.js and functions/rankedStreak.js).
///
/// The stored number is the streak as of the LAST qualifying day/week, so a
/// streak that has since lapsed still holds its old number until the next
/// vote or battle resets it. These helpers show 0 for a lapsed streak
/// instead of a stale number.
///
/// Judging: daily, Pacific day. Alive if counted today or yesterday.
/// Ranked: weekly, Pacific weeks starting Monday. Alive if counted this
/// week or last week.

String _key(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The Pacific calendar date for [now], as a UTC-midnight DateTime.
DateTime _pacificDate(DateTime now) {
  final p = now.toUtc().add(pacificOffset(now));
  return DateTime.utc(p.year, p.month, p.day);
}

/// Live judging-streak days (0 if lapsed).
int liveJudgeStreakDays(Object? voteStreak, {DateTime? now}) {
  if (voteStreak is! Map) return 0;
  final days = (voteStreak['days'] as num?)?.toInt() ?? 0;
  final today = _pacificDate(now ?? DateTime.now());
  final key = voteStreak['dayKey'];
  final alive =
      key == _key(today) ||
      key == _key(today.subtract(const Duration(days: 1)));
  return alive ? days : 0;
}

/// Live ranked-streak weeks (0 if lapsed).
int liveRankedStreakWeeks(Object? rankedStreak, {DateTime? now}) {
  if (rankedStreak is! Map) return 0;
  final weeks = (rankedStreak['weeks'] as num?)?.toInt() ?? 0;
  final today = _pacificDate(now ?? DateTime.now());
  final monday = today.subtract(Duration(days: today.weekday - 1));
  final key = rankedStreak['weekKey'];
  final alive =
      key == _key(monday) ||
      key == _key(monday.subtract(const Duration(days: 7)));
  return alive ? weeks : 0;
}
