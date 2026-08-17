/// The daily prime-time window ("Sixes and Sevens" — 6-7pm Pacific).
///
/// This is the cold-start liquidity fix: with a small user base spread
/// across timezones, live 1v1 pairing needs two people in the app at the
/// same minute, which essentially never happens by chance. Concentrating
/// everyone into one nightly hour multiplies effective concurrency by more
/// than an order of magnitude with no new matchmaking machinery.
///
/// ONE GLOBAL MOMENT, anchored to Pacific — deliberately NOT each viewer's
/// local 6-7pm. Firing locally would make the name literally true for
/// everyone but would split the pool into a separate small queue per
/// timezone, defeating the entire purpose. See CLAUDE.md.
///
/// Everything here is pure and timezone-explicit so it can be tested
/// without a device clock, which matters because the failure mode is a
/// countdown that is silently an hour wrong for a few weeks a year.
library;

/// Pacific standard offset (winter). Pacific daylight time is one hour
/// ahead of this.
const Duration _pacificStandardOffset = Duration(hours: -8);
const Duration _pacificDaylightOffset = Duration(hours: -7);

/// Configuration for the window, mirroring the `config/eventWindow`
/// Firestore document.
///
/// Read from config rather than hardcoded because BOTH THE NAME AND THE
/// HOURS ARE EXPLICITLY PROVISIONAL — the developer wants to revisit them,
/// and changing either must never require shipping a new app version. Same
/// reasoning as live match settings.
class EventWindowConfig {
  const EventWindowConfig({
    this.enabled = true,
    this.name = 'Sixes and Sevens',
    this.startHourPacific = 18,
    this.endHourPacific = 19,
  });

  final bool enabled;
  final String name;
  final int startHourPacific;
  final int endHourPacific;

  factory EventWindowConfig.fromMap(Map<String, dynamic>? data) {
    if (data == null) return const EventWindowConfig();
    const fallback = EventWindowConfig();
    // Bounds-checked for the same reason match settings are: this document
    // is hand-edited in the Firebase console with no validation layer in
    // between, and a start hour of 47 would produce a countdown to a moment
    // that never arrives. Each field falls back independently so one bad
    // value never discards a good rest.
    // The END may be 24, meaning midnight, so a window can cover the final
    // hour of the day - with a ceiling of 23 the range [23, end) had no
    // legal end at all. MUST match functions/eventWindow.js: if the two
    // disagree the app counts down to one time and the server notifies at
    // another, and nothing would surface it.
    int hour(String key, int fallbackValue, int max) {
      final raw = data[key];
      if (raw is! num) return fallbackValue;
      final value = raw.toInt();
      return (value >= 0 && value <= max) ? value : fallbackValue;
    }

    final start = hour('startHourPacific', fallback.startHourPacific, 23);
    var end = hour('endHourPacific', fallback.endHourPacific, 24);
    // An end at or before the start would make every window zero-length or
    // negative. Fall back rather than render nonsense.
    if (end <= start) end = fallback.endHourPacific;

    final name = data['name'];
    return EventWindowConfig(
      enabled: data['enabled'] is bool ? data['enabled'] as bool : fallback.enabled,
      name: (name is String && name.trim().isNotEmpty) ? name.trim() : fallback.name,
      startHourPacific: start,
      endHourPacific: end > start ? end : fallback.endHourPacific,
    );
  }
}

/// Whether an instant falls in US Pacific daylight time.
///
/// Implemented directly rather than via a timezone package: the US rule is
/// fixed by statute and short to express, and this project's Android
/// toolchain has a documented history of dependency conflicts. The rule is
/// second Sunday of March at 2am local standard (10:00 UTC) through first
/// Sunday of November at 2am local daylight (09:00 UTC).
bool isPacificDaylightTime(DateTime instant) {
  final utc = instant.toUtc();
  final start = _nthWeekdayOfMonth(utc.year, DateTime.march, DateTime.sunday, 2)
      .add(const Duration(hours: 10));
  final end = _nthWeekdayOfMonth(utc.year, DateTime.november, DateTime.sunday, 1)
      .add(const Duration(hours: 9));
  return !utc.isBefore(start) && utc.isBefore(end);
}

Duration pacificOffset(DateTime instant) =>
    isPacificDaylightTime(instant) ? _pacificDaylightOffset : _pacificStandardOffset;

/// Midnight UTC on the [n]th [weekday] of [month]. A calendar date's
/// weekday is the same in every timezone, so computing this in UTC gives
/// the right Pacific date.
DateTime _nthWeekdayOfMonth(int year, int month, int weekday, int n) {
  final first = DateTime.utc(year, month, 1);
  final delta = (weekday - first.weekday + 7) % 7;
  return first.add(Duration(days: delta + (n - 1) * 7));
}

/// One occurrence of the window, as absolute UTC instants.
class EventWindowOccurrence {
  const EventWindowOccurrence({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  bool contains(DateTime instant) {
    final utc = instant.toUtc();
    return !utc.isBefore(start) && utc.isBefore(end);
  }
}

/// The window occurrence that is either running right now or, if none is,
/// the next one to come.
///
/// Callers get an absolute UTC instant and format it in the viewer's own
/// timezone, which is what lets the UI show "6pm PT — 9pm your time"
/// without anyone doing timezone arithmetic by hand.
EventWindowOccurrence currentOrNextWindow(DateTime now, EventWindowConfig config) {
  final utc = now.toUtc();

  // Today's window, then tomorrow's, taking the first that hasn't ended.
  // Two candidates is always enough: a window is at most a day long and
  // recurs daily.
  for (var dayOffset = -1; dayOffset <= 1; dayOffset++) {
    final occurrence = _windowOnPacificDay(utc, dayOffset, config);
    if (utc.isBefore(occurrence.end)) return occurrence;
  }
  // Unreachable for any sane config, but returning tomorrow's is safer
  // than throwing inside a widget build.
  return _windowOnPacificDay(utc, 2, config);
}

/// The Pacific calendar date of the window people mean by "tonight" - the
/// one running now, or the next one if today's has finished.
///
/// Pre-commitments are keyed by this rather than by the viewer's local
/// date. Two different reasons, both load-bearing: a commitment made at
/// 8pm must book TOMORROW rather than an evening that has already passed,
/// and a viewer in Sydney whose local date is already tomorrow must still
/// commit to the same night as everyone else. The window is one global
/// moment, so the key has to be too.
///
/// Mirrors upcomingWindowDayKey in functions/eventWindow.js. If the two
/// disagree, someone commits to one night and is counted for another.
String upcomingWindowDayKey(DateTime now, EventWindowConfig config) {
  final window = currentOrNextWindow(now, config);
  final pacific = window.start.add(pacificOffset(window.start));
  final month = pacific.month.toString().padLeft(2, '0');
  final day = pacific.day.toString().padLeft(2, '0');
  return '${pacific.year}-$month-$day';
}

EventWindowOccurrence _windowOnPacificDay(
    DateTime utc, int dayOffset, EventWindowConfig config) {
  // Pacific wall-clock date for the day in question.
  final approxPacific = utc.add(pacificOffset(utc)).add(Duration(days: dayOffset));

  DateTime toUtcFromPacificWallClock(int hour) {
    final wall = DateTime.utc(
        approxPacific.year, approxPacific.month, approxPacific.day, hour);
    // Resolve the offset at the instant itself rather than at `now`: on a
    // DST-transition day those differ, and using `now`'s offset would put
    // the window an hour out for the whole day. One correction pass is
    // enough because transitions happen at 2am and this window doesn't.
    var guess = wall.subtract(pacificOffset(utc));
    guess = wall.subtract(pacificOffset(guess));
    return guess;
  }

  return EventWindowOccurrence(
    start: toUtcFromPacificWallClock(config.startHourPacific),
    end: toUtcFromPacificWallClock(config.endHourPacific),
  );
}
