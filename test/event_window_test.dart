import 'package:flutter_test/flutter_test.dart';
import 'package:bully_league/core/services/event_window.dart';

/// The daily window's clock arithmetic.
///
/// Worth real tests because the failure mode is invisible: a countdown
/// that's silently an hour wrong for the few weeks around a daylight-saving
/// transition looks completely normal, and the only symptom is people
/// showing up when nobody else does — which reads as "the app is dead"
/// rather than "the clock is off."
void main() {
  const config = EventWindowConfig();

  group('Pacific daylight time', () {
    test('is in effect in midsummer', () {
      expect(isPacificDaylightTime(DateTime.utc(2026, 7, 1)), isTrue);
    });

    test('is not in effect in midwinter', () {
      expect(isPacificDaylightTime(DateTime.utc(2026, 1, 15)), isFalse);
    });

    test('starts on the second Sunday of March at 2am local', () {
      // 2026: March 8th is the second Sunday. 2am PST is 10:00 UTC.
      expect(isPacificDaylightTime(DateTime.utc(2026, 3, 8, 9, 59)), isFalse);
      expect(isPacificDaylightTime(DateTime.utc(2026, 3, 8, 10, 0)), isTrue);
    });

    test('ends on the first Sunday of November at 2am local', () {
      // 2026: November 1st is the first Sunday. 2am PDT is 09:00 UTC.
      expect(isPacificDaylightTime(DateTime.utc(2026, 11, 1, 8, 59)), isTrue);
      expect(isPacificDaylightTime(DateTime.utc(2026, 11, 1, 9, 0)), isFalse);
    });

    test('handles a year where the month starts on a Sunday', () {
      // The nth-weekday arithmetic is easiest to get wrong when the 1st is
      // itself the target weekday. Nov 1 2026 is a Sunday, so the first
      // Sunday is the 1st, not the 8th.
      expect(isPacificDaylightTime(DateTime.utc(2026, 11, 7, 12)), isFalse);
    });
  });

  group('window placement', () {
    test('summer window is 6pm PDT, which is 01:00 UTC next day', () {
      final w = currentOrNextWindow(DateTime.utc(2026, 7, 1, 12), config);
      expect(w.start, DateTime.utc(2026, 7, 2, 1));
      expect(w.end, DateTime.utc(2026, 7, 2, 2));
    });

    test('winter window is 6pm PST, which is 02:00 UTC next day', () {
      final w = currentOrNextWindow(DateTime.utc(2026, 1, 15, 12), config);
      expect(w.start, DateTime.utc(2026, 1, 16, 2));
      expect(w.end, DateTime.utc(2026, 1, 16, 3));
    });

    test('the window is always exactly one hour by default', () {
      final w = currentOrNextWindow(DateTime.utc(2026, 7, 1, 12), config);
      expect(w.end.difference(w.start), const Duration(hours: 1));
    });

    test('a running window is returned rather than tomorrow\'s', () {
      // 01:30 UTC on July 2nd is 6:30pm PDT on July 1st - mid-window.
      final now = DateTime.utc(2026, 7, 2, 1, 30);
      final w = currentOrNextWindow(now, config);
      expect(w.contains(now), isTrue);
      expect(w.start, DateTime.utc(2026, 7, 2, 1));
    });

    test('the moment it ends, the next day\'s window is returned', () {
      final now = DateTime.utc(2026, 7, 2, 2);
      final w = currentOrNextWindow(now, config);
      expect(w.contains(now), isFalse);
      expect(w.start, DateTime.utc(2026, 7, 3, 1));
    });

    test('on the spring transition day the window is still 6pm Pacific', () {
      // The clocks moved forward at 2am that morning. Computing the offset
      // from "now" instead of from the window instant would put this an
      // hour out for the whole day.
      final now = DateTime.utc(2026, 3, 8, 12);
      final w = currentOrNextWindow(now, config);
      expect(w.start, DateTime.utc(2026, 3, 9, 1)); // 6pm PDT
    });

    test('on the autumn transition day the window is still 6pm Pacific', () {
      final now = DateTime.utc(2026, 11, 1, 12);
      final w = currentOrNextWindow(now, config);
      expect(w.start, DateTime.utc(2026, 11, 2, 2)); // 6pm PST
    });

    test('a viewer far from Pacific gets the same absolute instant', () {
      // The whole point of anchoring to one timezone: everyone converges on
      // one moment, whatever their local clock says.
      final fromTokyo = currentOrNextWindow(DateTime.utc(2026, 7, 1, 12), config);
      final fromLondon = currentOrNextWindow(DateTime.utc(2026, 7, 1, 12), config);
      expect(fromTokyo.start, fromLondon.start);
    });
  });

  group('config parsing', () {
    test('defaults apply when the document is missing entirely', () {
      final c = EventWindowConfig.fromMap(null);
      expect(c.enabled, isTrue);
      expect(c.startHourPacific, 18);
      expect(c.endHourPacific, 19);
    });

    test('a valid override is honoured', () {
      final c = EventWindowConfig.fromMap(
          {'name': 'Roast Hour', 'startHourPacific': 20, 'endHourPacific': 22});
      expect(c.name, 'Roast Hour');
      expect(c.startHourPacific, 20);
      expect(c.endHourPacific, 22);
    });

    test('an out-of-range hour falls back rather than breaking the clock', () {
      // Hand-edited in the console with no validation in between - a start
      // hour of 47 would count down to a moment that never arrives.
      final c = EventWindowConfig.fromMap({'startHourPacific': 47});
      expect(c.startHourPacific, 18);
    });

    test('an end at or before the start falls back', () {
      final c = EventWindowConfig.fromMap(
          {'startHourPacific': 18, 'endHourPacific': 18});
      expect(c.endHourPacific, 19);
    });

    test('one bad field does not discard the rest of a good config', () {
      final c = EventWindowConfig.fromMap(
          {'name': 'Roast Hour', 'startHourPacific': 'six'});
      expect(c.name, 'Roast Hour');
      expect(c.startHourPacific, 18);
    });

    test('a blank name falls back rather than rendering an empty banner', () {
      expect(EventWindowConfig.fromMap({'name': '   '}).name, 'Sixes and Sevens');
    });

    test('the window can be switched off entirely from config', () {
      expect(EventWindowConfig.fromMap({'enabled': false}).enabled, isFalse);
    });
  });
}
