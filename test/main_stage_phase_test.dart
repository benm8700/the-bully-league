import 'package:flutter_test/flutter_test.dart';
import 'package:bully_league/widgets/home/main_stage_marquee.dart';

void main() {
  // Next show: Thursday 2026-11-12 18:00 Pacific = Fri 02:00 UTC.
  final next = DateTime.utc(2026, 11, 13, 2);

  test('a normal day is the compact week card', () {
    expect(showPhaseAt(DateTime.utc(2026, 11, 10, 20), next), ShowPhase.week);
  });

  test('within 12h of the show it is show day (big card on top)', () {
    expect(showPhaseAt(DateTime.utc(2026, 11, 12, 15), next), ShowPhase.showDay);
  });

  test('just over 12h out is still the week card', () {
    expect(showPhaseAt(DateTime.utc(2026, 11, 12, 13, 59), next), ShowPhase.week);
  });

  test('the 3 hours after a show start are LIVE', () {
    // Now is 1h after LAST week's show; the helper already returns next week's.
    final now = DateTime.utc(2026, 11, 6, 3);
    final nextFromThen = DateTime.utc(2026, 11, 13, 2);
    expect(showPhaseAt(now, nextFromThen), ShowPhase.live);
  });

  test('after the 3-hour show window it goes back to the week card', () {
    expect(showPhaseAt(DateTime.utc(2026, 11, 6, 5, 1), next), ShowPhase.week);
  });
}
