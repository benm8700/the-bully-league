import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// A player's paid-panel-seat state for the current week.
///
/// Mirrors functions/judgeSeatPlay.js (getJudgeSeatState). The server holds the
/// config, the eligibility gate, the sold count and the balance; this is only
/// what the buy UI renders.
///
/// Gated behind config/tournament.enabled AND judgeSeatsEnabled, so `enabled` is
/// false until both flip - and the UI renders nothing while it is, so the seat
/// is never offered before it can be bought.
@immutable
class JudgeSeatState {
  const JudgeSeatState({
    required this.enabled,
    this.weekKey,
    this.price = 0,
    this.seatsTotal = 0,
    this.seatsSold = 0,
    this.seatsRemaining = 0,
    this.youHold = false,
    this.eligible = false,
    this.reason,
    this.message,
    this.balance = 0,
  });

  final bool enabled;
  final String? weekKey;

  /// Fixed points price of one seat.
  final int price;

  /// How many seats are buyable this week (the minority cap), and how many are
  /// gone / left.
  final int seatsTotal;
  final int seatsSold;
  final int seatsRemaining;

  /// Whether this account already holds a seat this week.
  final bool youHold;

  /// Whether this account may buy (active + has judged enough). When false,
  /// `message` says what's missing.
  final bool eligible;
  final String? reason;
  final String? message;

  /// Spendable points balance.
  final int balance;

  bool get soldOut => seatsRemaining <= 0;

  factory JudgeSeatState.fromMap(Map<String, dynamic> d) {
    return JudgeSeatState(
      enabled: d['enabled'] == true,
      weekKey: d['weekKey'] as String?,
      price: (d['price'] as num?)?.toInt() ?? 0,
      seatsTotal: (d['seatsTotal'] as num?)?.toInt() ?? 0,
      seatsSold: (d['seatsSold'] as num?)?.toInt() ?? 0,
      seatsRemaining: (d['seatsRemaining'] as num?)?.toInt() ?? 0,
      youHold: d['youHold'] == true,
      eligible: d['eligible'] == true,
      reason: d['reason'] as String?,
      message: d['message'] as String?,
      balance: (d['balance'] as num?)?.toInt() ?? 0,
    );
  }
}

class JudgeSeatService {
  JudgeSeatService({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  /// Current seat state, or null if it can't be reached. A failure hides the
  /// buy surface rather than showing a broken one - the seat is an extra path,
  /// so silence is the safe direction.
  Future<JudgeSeatState?> state() async {
    try {
      final result = await _functions
          .httpsCallable('getJudgeSeatState')
          .call<Map<String, dynamic>>();
      return JudgeSeatState.fromMap(result.data);
    } catch (_) {
      return null;
    }
  }

  /// Buy a seat. Throws on failure (ineligible, sold out, can't afford, closed)
  /// so the caller can surface the reason.
  Future<void> buy() async {
    await _functions.httpsCallable('buyJudgeSeat').call<Map<String, dynamic>>();
  }
}
