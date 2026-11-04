import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// The TRY-OUT TICKET state for the signed-in player.
///
/// Mirrors functions/tournamentTicket.js (getTournamentTicketState). Holding a
/// ticket for the current qualifying period is what makes your weekly-Elo
/// eligible to be PICKED UP for the Main Stage finals; without one you still
/// play ranked, you just aren't drawn into the field. Members (subscriber or
/// in trial) claim it free; everyone else pays [price] points.
///
/// Gated behind config/tournament.enabled AND tryoutTicketEnabled, so [enabled]
/// is false until both are flipped. The Home banner renders NOTHING while it is
/// false (or once [held] is true), so a secured/offline tournament never
/// clutters Home.
@immutable
class TournamentTicketState {
  const TournamentTicketState({
    required this.enabled,
    this.held = false,
    this.member = false,
    this.price = 0,
    this.balance = 0,
    this.weekKey,
    this.cutoffMs,
  });

  /// Whether ticketing is live. When false, nothing else here is meaningful
  /// and every ticket surface hides itself.
  final bool enabled;

  /// Whether this account already holds a ticket for the current period.
  final bool held;

  /// A subscriber or trial member, who claims the ticket free.
  final bool member;

  /// The points price for a non-member. 0 for a member (free claim).
  final int price;

  /// The player's spendable points balance.
  final int balance;

  /// The qualifying period this ticket is for (its cutoff day key).
  final String? weekKey;

  /// Epoch ms of the deadline (period cutoff, Thursday 00:00 Pacific); the
  /// ticket must be secured before this.
  final int? cutoffMs;

  /// Whether to show the "secure your ticket" nudge: live, not yet held.
  bool get showPrompt => enabled && !held;

  /// Whether a non-member can currently afford it.
  bool get affordable => member || balance >= price;

  factory TournamentTicketState.fromMap(Map<String, dynamic> d) {
    return TournamentTicketState(
      enabled: d['enabled'] == true,
      held: d['held'] == true,
      member: d['member'] == true,
      price: (d['price'] as num?)?.toInt() ?? 0,
      balance: (d['balance'] as num?)?.toInt() ?? 0,
      weekKey: d['weekKey'] as String?,
      cutoffMs: (d['cutoffMs'] as num?)?.toInt(),
    );
  }
}

class TournamentTicketService {
  TournamentTicketService({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  /// Current ticket state, or null if it can't be reached. A failure hides the
  /// banner rather than showing a broken one - a dropped fetch must never look
  /// like a locked tournament.
  Future<TournamentTicketState?> state() async {
    try {
      final result = await _functions
          .httpsCallable('getTournamentTicketState')
          .call<Map<String, dynamic>>();
      return TournamentTicketState.fromMap(result.data);
    } catch (_) {
      return null;
    }
  }

  /// Secure this period's ticket (spends points, or free for a member). Throws
  /// on failure (can't afford, ticketing off) so the caller can surface it.
  Future<void> secure() async {
    await _functions
        .httpsCallable('secureTournamentTicket')
        .call<Map<String, dynamic>>();
  }
}
