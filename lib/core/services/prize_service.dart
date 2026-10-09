import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// A non-cash prize this player has won and not yet claimed.
@immutable
class OwedPrize {
  const OwedPrize({
    required this.id,
    required this.prize,
    this.tournamentName,
    this.wonAtMs,
  });

  final String id;
  final String prize;
  final String? tournamentName;
  final int? wonAtMs;
}

/// Reads the player's owed prizes and submits their shipping details.
/// Mirrors functions/prizes.js; the server owns the records.
class PrizeService {
  PrizeService({FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _db = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  /// Prizes won but not yet claimed. Queries by `winnerUid` (which the
  /// firestore rule lets the owner read) and filters to `owed` in code, so no
  /// composite index is needed. Returns [] on any error — a prize banner that
  /// can't load simply doesn't show.
  Future<List<OwedPrize>> myOwedPrizes() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const [];
    try {
      final snap = await _db
          .collection('prizeFulfillments')
          .where('winnerUid', isEqualTo: uid)
          .get();
      return snap.docs
          .where((d) => d.data()['status'] == 'owed')
          .map((d) {
            final x = d.data();
            return OwedPrize(
              id: d.id,
              prize: (x['prize'] as String?) ?? 'a prize',
              tournamentName: x['tournamentName'] as String?,
              wonAtMs: (x['wonAtMs'] as num?)?.toInt(),
            );
          })
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Submit shipping/contact for a prize. Throws on failure so the form can
  /// surface the reason (only the winner may claim; the server enforces it).
  Future<void> submitClaim({
    required String fulfillmentId,
    required String name,
    required String address,
    required String phone,
  }) async {
    await _functions.httpsCallable('submitPrizeClaim').call<Map<String, dynamic>>({
      'fulfillmentId': fulfillmentId,
      'name': name,
      'address': address,
      'phone': phone,
    });
  }
}
