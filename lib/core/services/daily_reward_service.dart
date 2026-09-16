import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// The daily-login-reward state for the signed-in player.
///
/// Mirrors functions/dailyReward.js. The server is the authority (it mints
/// the points and owns the cycle), so this exists only to render the reward
/// calendar and drive the claim button.
@immutable
class DailyRewardState {
  const DailyRewardState({
    required this.enabled,
    required this.schedule,
    required this.cycleLength,
    required this.cycleDay,
    required this.todaysReward,
    required this.claimable,
    required this.claimedToday,
  });

  final bool enabled;

  /// The full escalating point schedule, one entry per cycle day.
  final List<int> schedule;
  final int cycleLength;

  /// The 1-based cycle day today's claim lands on (or landed on, if already
  /// claimed today).
  final int cycleDay;
  final int todaysReward;

  /// Whether the reward can be claimed right now.
  final bool claimable;
  final bool claimedToday;

  factory DailyRewardState.fromMap(Map<String, dynamic> data) {
    final raw = (data['schedule'] as List?) ?? const [];
    return DailyRewardState(
      enabled: data['enabled'] == true,
      schedule: raw.map((v) => (v as num?)?.toInt() ?? 0).toList(),
      cycleLength: (data['cycleLength'] as num?)?.toInt() ?? raw.length,
      cycleDay: (data['cycleDay'] as num?)?.toInt() ?? 1,
      todaysReward: (data['todaysReward'] as num?)?.toInt() ?? 0,
      claimable: data['claimable'] == true,
      claimedToday: data['claimedToday'] == true,
    );
  }
}

/// The result of a claim attempt.
@immutable
class DailyRewardClaim {
  const DailyRewardClaim({
    required this.claimed,
    required this.reward,
    required this.cycleDay,
  });

  final bool claimed;
  final int reward;
  final int cycleDay;
}

class DailyRewardService {
  DailyRewardService({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  /// Current reward state, or null if it can't be reached. A failure hides
  /// the "claim ready" affordance rather than showing a false one - the
  /// reward is a bonus, so silence is the safe direction.
  Future<DailyRewardState?> state() async {
    try {
      final result = await _functions
          .httpsCallable('getDailyRewardState')
          .call<Map<String, dynamic>>();
      return DailyRewardState.fromMap(result.data);
    } catch (_) {
      return null;
    }
  }

  /// Claim today's reward. Throws on failure (already claimed, disabled,
  /// network) so the sheet can surface the reason.
  Future<DailyRewardClaim> claim() async {
    final result = await _functions
        .httpsCallable('claimDailyReward')
        .call<Map<String, dynamic>>();
    final data = result.data;
    return DailyRewardClaim(
      claimed: data['claimed'] == true,
      reward: (data['reward'] as num?)?.toInt() ?? 0,
      cycleDay: (data['cycleDay'] as num?)?.toInt() ?? 1,
    );
  }
}
