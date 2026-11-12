import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// The WILDCARD auction state for the signed-in player.
///
/// Mirrors functions/wildcardAuctionPlay.js (getWildcardAuctionState). The
/// server is the authority - it holds the config, the eligibility gate, the
/// sealed bids and the balance - so this is purely what the bid UI renders.
///
/// The whole feature is gated behind config/tournament.enabled AND
/// wildcardAuctionEnabled, so `enabled` is false until both are flipped. Every
/// surface that shows the wildcard renders NOTHING while it is false, so the
/// seat is never teased before it can actually be bid on.
@immutable
class WildcardAuctionState {
  const WildcardAuctionState({
    required this.enabled,
    this.weekKey,
    this.cutoffMs,
    this.entryFee = 0,
    this.bidFloor = 0,
    this.eligible = false,
    this.reason,
    this.message,
    this.balance = 0,
    this.yourBid,
  });

  /// Whether the auction is open for bids at all. When false, nothing else on
  /// this object is meaningful and every wildcard surface hides itself.
  final bool enabled;

  /// The qualifying week this bid is for (the upcoming show's cutoff day).
  final String? weekKey;

  /// Epoch ms of that week's cutoff (Thursday 00:00 Pacific); bidding closes
  /// then. Null only when the auction is off.
  final int? cutoffMs;

  /// The fixed, non-refundable buy-in charged once on your first bid.
  final int entryFee;

  /// The smallest legal bid.
  final int bidFloor;

  /// Whether this account may bid (active + intro video + profile photo +
  /// enough ranked games). When false, `message` says what's missing.
  final bool eligible;
  final String? reason;
  final String? message;

  /// The player's spendable points balance.
  final int balance;

  /// The player's current sealed bid for this week, or null if they haven't
  /// bid yet.
  final int? yourBid;

  bool get hasBid => yourBid != null;

  factory WildcardAuctionState.fromMap(Map<String, dynamic> d) {
    return WildcardAuctionState(
      enabled: d['enabled'] == true,
      weekKey: d['weekKey'] as String?,
      cutoffMs: (d['cutoffMs'] as num?)?.toInt(),
      entryFee: (d['entryFee'] as num?)?.toInt() ?? 0,
      bidFloor: (d['bidFloor'] as num?)?.toInt() ?? 0,
      eligible: d['eligible'] == true,
      reason: d['reason'] as String?,
      message: d['message'] as String?,
      balance: (d['balance'] as num?)?.toInt() ?? 0,
      yourBid: (d['yourBid'] as num?)?.toInt(),
    );
  }
}

/// The result of a placed/raised bid.
@immutable
class WildcardBidResult {
  const WildcardBidResult({required this.amount, required this.feeCharged});

  final int amount;

  /// True only on the first bid of the week, when the one-time entry fee was
  /// taken. A raise never charges it again.
  final bool feeCharged;
}

class WildcardAuctionService {
  WildcardAuctionService({FirebaseFunctions? functions})
    : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  /// Current auction state, or null if it can't be reached. A failure hides
  /// the wildcard surfaces rather than showing a broken one - the seat is a
  /// bonus path, so silence is the safe direction.
  Future<WildcardAuctionState?> state() async {
    try {
      final result = await _functions
          .httpsCallable('getWildcardAuctionState')
          .call<Map<String, dynamic>>();
      return WildcardAuctionState.fromMap(result.data);
    } catch (_) {
      return null;
    }
  }

  /// Place or raise a sealed bid. Throws on failure (ineligible, below floor,
  /// can't afford, auction closed) so the sheet can surface the reason.
  Future<WildcardBidResult> placeBid(int amount) async {
    final result = await _functions
        .httpsCallable('placeWildcardBid')
        .call<Map<String, dynamic>>({'amount': amount});
    final data = result.data;
    return WildcardBidResult(
      amount: (data['amount'] as num?)?.toInt() ?? amount,
      feeCharged: data['feeCharged'] == true,
    );
  }
}
