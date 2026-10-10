import 'package:bully_league/core/badges/badges.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Juror judging-volume family (votesCast)', () {
    test('earns tier 1 at 10 votes, tier 2 at 100', () {
      final q10 = qualifyingBadgeIds(const BadgeStats(
          wins: 0, battlesPlayed: 0, voteStreakDays: 0, votesCast: 10));
      expect(q10, contains('juror_1'));
      expect(q10, isNot(contains('juror_2')));

      final q137 = qualifyingBadgeIds(const BadgeStats(
          wins: 0, battlesPlayed: 0, voteStreakDays: 0, votesCast: 137));
      expect(q137, containsAll(['juror_1', 'juror_2']));
      expect(q137, isNot(contains('juror_3')));
    });

    test('reads votesCast off the user doc', () {
      final stats = BadgeStats.fromUser({'votesCast': 42});
      expect(stats.votesCast, 42);
      expect(stats.value(BadgeMetric.votesCast), 42);
    });

    test('the family shows its highest earned tier with the next goal', () {
      final stats = const BadgeStats(
          wins: 0, battlesPlayed: 0, voteStreakDays: 0, votesCast: 137);
      final earned = qualifyingBadgeIds(stats);
      final slots = badgeSlots(stats, earned);
      final juror = slots.firstWhere((s) => s.def.family == 'juror');
      expect(juror.def.id, 'juror_2', reason: 'highest earned tier is Magistrate');
      expect(juror.earned, isTrue);
      expect(juror.goal, 500, reason: 'next goal is Chief Justice');
    });
  });

  test('the Champion award is NOT grantable via the client earned set', () {
    // tournament_champion is server-field-only (tournamentWins), so injecting
    // it into badges.earned must be stripped.
    final earned = resolveEarnedIds({
      'badges': {
        'earned': ['tournament_champion', 'first_blood'],
      },
      'wins': 1,
    });
    expect(earned, isNot(contains('tournament_champion')));
    expect(earned, contains('first_blood'));
  });

  test('a real tournament win DOES earn the Champion badge', () {
    final earned = resolveEarnedIds({'tournamentWins': 2});
    expect(earned, contains('tournament_champion'));
  });

  test('the Runner-Up award is server-only, not client-injectable', () {
    final injected = resolveEarnedIds({
      'badges': {
        'earned': ['tournament_runner_up'],
      },
    });
    expect(injected, isNot(contains('tournament_runner_up')));
    // ...but a real runner-up count earns it.
    final earned = resolveEarnedIds({'tournamentRunnerUps': 1});
    expect(earned, contains('tournament_runner_up'));
  });
}
