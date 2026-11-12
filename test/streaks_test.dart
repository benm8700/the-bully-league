import 'package:flutter_test/flutter_test.dart';
import 'package:bully_league/core/streaks.dart';

void main() {
  // Wednesday 2026-11-11, midday Pacific.
  final now = DateTime.utc(2026, 11, 11, 20);

  test('judging streak alive today or yesterday, else 0', () {
    expect(
      liveJudgeStreakDays({'days': 4, 'dayKey': '2026-11-11'}, now: now),
      4,
    );
    expect(
      liveJudgeStreakDays({'days': 4, 'dayKey': '2026-11-10'}, now: now),
      4,
    );
    expect(
      liveJudgeStreakDays({'days': 4, 'dayKey': '2026-11-09'}, now: now),
      0,
    );
    expect(liveJudgeStreakDays(null, now: now), 0);
  });

  test('judging day is Pacific, not UTC', () {
    // 2026-11-12 03:00 UTC is still Nov 11, 7pm Pacific.
    final evening = DateTime.utc(2026, 11, 12, 3);
    expect(
      liveJudgeStreakDays({'days': 2, 'dayKey': '2026-11-10'}, now: evening),
      2,
    );
  });

  test(
    'ranked streak alive this week or last, else 0 (weeks start Monday)',
    () {
      expect(
        liveRankedStreakWeeks({'weeks': 3, 'weekKey': '2026-11-09'}, now: now),
        3,
      );
      expect(
        liveRankedStreakWeeks({'weeks': 3, 'weekKey': '2026-11-02'}, now: now),
        3,
      );
      expect(
        liveRankedStreakWeeks({'weeks': 3, 'weekKey': '2026-10-26'}, now: now),
        0,
      );
    },
  );
}
