import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';

/// Client wrapper for the match-ABILITIES (power-ups) callables
/// (functions/abilities.js). The server is the authority: a player's loadout
/// is server-only (secret from the opponent), points are spent server-side.
///
/// This is the ECONOMY layer only and is FORMAT-INDEPENDENT. The in-match
/// EFFECT of deploying an ability (e.g. interrupt = steal the turn) is applied
/// match-side and is format-specific - that is deliberately NOT here.
class AbilitiesService {
  static final _fns = FirebaseFunctions.instance;
  static final _rand = Random();

  /// The pre-match loadout for [matchId]: whether abilities are on, the
  /// player's spendable balance, and each ability's cost/owned/cap. Throws on
  /// a backend/auth error - callers decide whether to fail quiet.
  static Future<Loadout> getLoadout(String matchId) async {
    final r = await _fns
        .httpsCallable('getLoadout')
        .call<Object?>({'matchId': matchId});
    return Loadout.fromMap(_asMap(r.data));
  }

  /// Buy ONE of [abilityId] for [matchId]. Idempotent via a fresh requestId, so
  /// a network retry never double-charges. Returns the raw server result
  /// (ok/bought/balance, or throws a FirebaseFunctionsException on refusal).
  static Future<Map<String, dynamic>> buyAbility({
    required String matchId,
    required String abilityId,
  }) async {
    final requestId =
        'ab_${DateTime.now().microsecondsSinceEpoch}_${_rand.nextInt(1 << 32)}';
    final r = await _fns.httpsCallable('purchaseAbility').call<Object?>({
      'matchId': matchId,
      'abilityId': abilityId,
      'requestId': requestId,
    });
    return _asMap(r.data);
  }
}

/// Firebase callables hand nested maps back as `Map<Object?, Object?>`;
/// normalise to `Map<String, dynamic>` so field reads are safe.
Map<String, dynamic> _asMap(Object? o) =>
    (o as Map?)?.map((k, v) => MapEntry(k.toString(), v)) ??
    <String, dynamic>{};

int _asInt(Object? o) => (o as num?)?.toInt() ?? 0;

/// A player's pre-match loadout for one match.
class Loadout {
  const Loadout({
    required this.enabled,
    required this.balance,
    required this.matchId,
    required this.abilities,
  });

  /// False when abilities are switched off in config - the UI shows nothing.
  final bool enabled;

  /// Spendable points (career total is never touched by spending).
  final int balance;
  final String matchId;
  final List<AbilityOption> abilities;

  factory Loadout.fromMap(Map<String, dynamic> m) {
    final raw = (m['abilities'] as List?) ?? const [];
    return Loadout(
      enabled: m['enabled'] == true,
      balance: _asInt(m['balance']),
      matchId: m['matchId']?.toString() ?? '',
      abilities: raw.map((e) => AbilityOption.fromMap(_asMap(e))).toList(),
    );
  }

  /// True when there's anything worth showing (on, and at least one ability).
  bool get hasAny => enabled && abilities.isNotEmpty;
}

/// One ability as offered for a match, with how many the player already has.
class AbilityOption {
  const AbilityOption({
    required this.id,
    required this.name,
    required this.description,
    required this.cost,
    required this.free,
    required this.bought,
    required this.total,
    required this.max,
    required this.canBuy,
  });

  final String id;
  final String name;
  final String description;

  /// Points per extra one beyond the free allowance.
  final int cost;

  /// Included free this match (a subscriber/trial perk).
  final int free;

  /// Bought with points so far this match.
  final int bought;

  /// free + bought - how many are equipped for the match.
  final int total;

  /// Per-match cap (free counts toward it).
  final int max;

  /// Whether one more can be bought right now (under the cap, affordable).
  final bool canBuy;

  bool get atCap => total >= max;

  factory AbilityOption.fromMap(Map<String, dynamic> m) => AbilityOption(
        id: m['id']?.toString() ?? '',
        name: m['name']?.toString() ?? '',
        description: m['description']?.toString() ?? '',
        cost: _asInt(m['cost']),
        free: _asInt(m['free']),
        bought: _asInt(m['bought']),
        total: _asInt(m['total']),
        max: _asInt(m['max']),
        canBuy: m['canBuy'] == true,
      );
}
