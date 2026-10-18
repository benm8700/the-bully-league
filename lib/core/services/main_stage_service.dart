import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../main_stage_battle.dart' show kMainStageGraceDefaultMs;

/// Where the viewer stands in a Main Stage (weekly finals) tournament. Computed
/// purely from the tournament document + the viewer's uid, so the screen can
/// render the right state without a round-trip. Mirrors the server lifecycle in
/// functions/mainStageTournament.js + mainStageLifecycle.js.
enum MainStageRole { finalist, alternate, judge, none }

/// The viewer's invite answer, read from the doc's `invites` map.
enum InviteStatus { pending, accepted, declined, notInvited }

/// Where a finalist stands DURING the live show, so the screen routes them
/// without dumping them back to Home to re-find a banner:
///  - playNow: their matchup is ready and unplayed - step on stage.
///  - awaitingVerdict: they finished their battle; the judges are deciding.
///  - advancedWaiting: they won and are through, but their next opponent isn't
///    settled yet (the other semifinal is still going) - watch it.
///  - eliminated: they lost - watch the rest.
///  - champion: they won the final.
///  - spectate: not a player in any live matchup (crowd / judge / waiting).
enum MainStageLiveStage {
  playNow,
  awaitingVerdict,
  advancedWaiting,
  eliminated,
  champion,
  spectate,
}

@immutable
class MainStageView {
  const MainStageView({
    required this.tournamentId,
    required this.status,
    required this.role,
    required this.invite,
    required this.isTopSeed,
    required this.finalists,
    required this.field,
    required this.candidates,
    this.wildCardUid,
    this.myMatchupRound,
    this.myMatchupIndex,
    this.myMatchupIsFinal = false,
    this.liveStage = MainStageLiveStage.spectate,
    this.liveBattleMatchId,
  });

  final String tournamentId;

  /// accepting | locked | live | completed | cancelled (server-authored).
  final String status;
  final MainStageRole role;
  final InviteStatus invite;

  /// True only once the field is locked AND the viewer is field[0] — the one
  /// who makes the callout. There is nothing to show the #1 before the lock,
  /// since the field isn't settled yet.
  final bool isTopSeed;

  /// The seed-ordered finalists from the snapshot (known from Wednesday night,
  /// before the 4pm lock) - [skill1, skill2, skill3, wildCard]. Use this to show
  /// the announced field + the wild-card reveal while status is 'accepting'.
  final List<String> finalists;

  /// The locked field (seed order), empty until the 4pm lock.
  final List<String> field;

  /// The seat-4 WILD CARD uid (drawn from the field by engagement), or null if
  /// the field was too small to draw one. Mark whichever seed matches this.
  final String? wildCardUid;

  /// The opponents the #1 may call out: the locked field minus themselves.
  /// Empty unless [isTopSeed] and the callout is open (status == locked).
  final List<String> candidates;

  /// The viewer's READY, UNPLAYED matchup (both players known, no winner, and
  /// NOT yet started - no matchId), once the show is live. Only set when
  /// [liveStage] is playNow; null otherwise.
  final int? myMatchupRound;
  final int? myMatchupIndex;

  /// Whether [myMatchupRound] is the final round (the last bracket round), so
  /// the screen can say "the FINAL" rather than "your match".
  final bool myMatchupIsFinal;

  /// Where the viewer stands in the live show (see [MainStageLiveStage]).
  final MainStageLiveStage liveStage;

  /// The battle currently ON STAGE, if any - the one matchup with a started
  /// match (a stamped matchId) and no winner yet. Main Stage runs one battle
  /// at a time, so there is at most one. This is what judges judge and the
  /// crowd watches. Null between battles (nobody has stepped on stage yet).
  final String? liveBattleMatchId;

  bool get calloutOpen => isTopSeed && status == 'locked';
  bool get hasBattleToPlay => liveStage == MainStageLiveStage.playNow &&
      myMatchupRound != null && myMatchupIndex != null;
}

/// Reads the Main Stage tournament and drives its two player-facing callables
/// (respond to invite, make the callout). The admin-only setMainStageJudges is
/// deliberately NOT wrapped here — it belongs to the web admin dashboard.
class MainStageService {
  MainStageService({FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _db = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  /// The current Main Stage tournament, if one is live in the lifecycle. There
  /// is at most one at a time (`mainstage_<cutoffDayKey>`), so the newest
  /// non-terminal doc is it. Returns null when there is none — the common case,
  /// since the whole system is flag-gated OFF until launch.
  /// A single-field equality query (no composite index needed); the active doc
  /// is picked and the terminal ones filtered out in Dart. There is only ever a
  /// handful of mainstage docs (one per week), so reading them is cheap.
  static const _active = {'accepting', 'locked', 'live'};

  Stream<MainStageView?> watch() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return _db
        .collection('tournaments')
        .where('format', isEqualTo: 'mainstage')
        .snapshots()
        .map((snap) {
      if (uid == null) return null;
      final live = snap.docs
          .where((d) => _active.contains(d.data()['status']))
          .toList()
        ..sort((a, b) => _createdMs(b.data()).compareTo(_createdMs(a.data())));
      if (live.isEmpty) return null;
      return _view(live.first.id, live.first.data(), uid);
    });
  }

  static int _createdMs(Map<String, dynamic> t) {
    final c = t['createdAt'];
    if (c is Timestamp) return c.millisecondsSinceEpoch;
    if (c is int) return c;
    return 0;
  }

  MainStageView _view(String id, Map<String, dynamic> t, String uid) {
    final finalists = _strList(t['finalists']);
    final alternates = _strList(t['alternates']);
    final judgePool = _strList(t['judgePool']);
    final handPicked = _strList(t['handPickedJudges']);
    final field = _strList(t['field']);
    final invites = (t['invites'] as Map?) ?? const {};
    final status = (t['status'] as String?) ?? 'accepting';

    MainStageRole role;
    if (finalists.contains(uid)) {
      role = MainStageRole.finalist;
    } else if (alternates.contains(uid)) {
      role = MainStageRole.alternate;
    } else if (handPicked.contains(uid) || judgePool.contains(uid)) {
      role = MainStageRole.judge;
    } else {
      role = MainStageRole.none;
    }

    InviteStatus invite;
    final raw = invites[uid];
    if (raw == 'accepted') {
      invite = InviteStatus.accepted;
    } else if (raw == 'declined') {
      invite = InviteStatus.declined;
    } else if (raw == 'pending') {
      invite = InviteStatus.pending;
    } else {
      invite = InviteStatus.notInvited;
    }

    final isTopSeed = field.isNotEmpty && field.first == uid;
    final candidates =
        isTopSeed ? field.where((u) => u != uid).toList() : const <String>[];

    // The viewer's live standing + the one battle currently on stage. The
    // bracket is the Firestore-safe shape {rounds: [{matches: [{a, b, winner,
    // matchId?}]}]}; a matchup gets a matchId once someone starts it
    // (mainStagePlay.js) and a winner once the judges decide.
    int? myRound;
    int? myIdx;
    var myIsFinal = false;
    var liveStage = MainStageLiveStage.spectate;
    String? liveBattleMatchId;
    if (status == 'live') {
      final rounds = (t['bracket'] as Map?)?['rounds'];
      if (rounds is List && rounds.isNotEmpty) {
        final lastRound = rounds.length - 1;
        // The battle on stage to WATCH/JUDGE (started = has a matchId, no
        // winner), across the whole bracket.
        for (final r in rounds) {
          final matches = (r as Map?)?['matches'];
          if (matches is! List) continue;
          for (final m in matches) {
            if (m is! Map) continue;
            final mid = m['matchId'];
            if (m['winner'] == null && mid is String && mid.isNotEmpty) {
              liveBattleMatchId = mid;
            }
          }
        }
        // Where the VIEWER stands: the HIGHEST round they appear in is their
        // current position (winning a round places them in the next one).
        int? hiR;
        int? hiM;
        for (var ri = 0; ri < rounds.length; ri++) {
          final matches = (rounds[ri] as Map?)?['matches'];
          if (matches is! List) continue;
          for (var mi = 0; mi < matches.length; mi++) {
            final m = matches[mi];
            if (m is Map && (m['a'] == uid || m['b'] == uid)) {
              hiR = ri;
              hiM = mi;
            }
          }
        }
        if (hiR != null) {
          final m = (rounds[hiR] as Map)['matches'][hiM] as Map;
          final winner = m['winner'];
          final mid = m['matchId'];
          final opponent = m['a'] == uid ? m['b'] : m['a'];
          final started = mid is String && mid.isNotEmpty;
          if (winner != null) {
            liveStage = winner == uid
                ? (hiR == lastRound
                    ? MainStageLiveStage.champion
                    // Won a non-final round but not yet placed in the next -
                    // transient; show "through, waiting".
                    : MainStageLiveStage.advancedWaiting)
                : MainStageLiveStage.eliminated;
          } else if (started) {
            // Battle in progress or played and awaiting the verdict - NOT a
            // fresh "Play your match" (that was the stale-banner bug).
            liveStage = MainStageLiveStage.awaitingVerdict;
          } else if (opponent == null) {
            // Through to this round, opponent not settled yet (the other
            // semifinal is still going).
            liveStage = MainStageLiveStage.advancedWaiting;
          } else {
            liveStage = MainStageLiveStage.playNow;
            myRound = hiR;
            myIdx = hiM;
            myIsFinal = hiR == lastRound;
          }
        }
      }
    }

    return MainStageView(
      tournamentId: id,
      status: status,
      role: role,
      invite: invite,
      isTopSeed: isTopSeed,
      finalists: finalists,
      field: field,
      candidates: candidates,
      wildCardUid: t['wildCardUid'] as String?,
      myMatchupRound: myRound,
      myMatchupIndex: myIdx,
      myMatchupIsFinal: myIsFinal,
      liveStage: liveStage,
      liveBattleMatchId: liveBattleMatchId,
    );
  }

  static List<String> _strList(dynamic v) =>
      v is List ? v.whereType<String>().toList() : const [];

  /// Confirm or decline a finalist/alternate invite. Throws on failure so the
  /// screen can surface the server's reason (only an invited player, only while
  /// accepting).
  Future<void> respondToInvite(String tournamentId, bool accept) async {
    await _functions
        .httpsCallable('respondToMainStageInvite')
        .call<Map<String, dynamic>>({
      'tournamentId': tournamentId,
      'accept': accept,
    });
  }

  /// The #1 seed's live callout. Throws on failure (only field[0], only while
  /// locked, pick must be another finalist — all re-checked server-side).
  Future<void> callout(String tournamentId, String pickUid) async {
    await _functions
        .httpsCallable('mainStageCallout')
        .call<Map<String, dynamic>>({
      'tournamentId': tournamentId,
      'pickUid': pickUid,
    });
  }

  /// Start (or rejoin) a finals bracket battle. Returns the pairing the
  /// chess-clock battle screen consumes. Both named players call this and get
  /// the SAME match (the server stamps the id onto the bracket matchup).
  Future<MainStageBattlePairing> startBattle({
    required String tournamentId,
    required int roundIdx,
    required int matchIdx,
  }) async {
    final res = await _functions
        .httpsCallable('startMainStageBattle')
        .call<Map<String, dynamic>>({
      'tournamentId': tournamentId,
      'roundIdx': roundIdx,
      'matchIdx': matchIdx,
    });
    final d = Map<String, dynamic>.from(res.data as Map);
    final cfg = Map<String, dynamic>.from(d['mainStageConfig'] as Map? ?? {});
    return MainStageBattlePairing(
      matchId: d['matchId'] as String,
      channelName: d['channelName'] as String,
      opponentId: d['opponentId'] as String,
      agoraUid: (d['agoraUid'] as num).toInt(),
      turnMs: (cfg['turnMs'] as num?)?.toInt() ?? 60000,
      interrupts: (cfg['interrupts'] as num?)?.toInt() ?? 2,
      shotClockMs: (cfg['shotClockMs'] as num?)?.toInt() ?? 7000,
      graceMs: (cfg['graceMs'] as num?)?.toInt() ?? kMainStageGraceDefaultMs,
    );
  }

  /// A seated judge casts (or changes) their open vote. Throws if the caller
  /// isn't on the panel (server-enforced).
  Future<void> castJudgeVote(String matchId, String winnerUid) async {
    await _functions
        .httpsCallable('castMainStageJudgeVote')
        .call<Map<String, dynamic>>({
      'matchId': matchId,
      'winnerUid': winnerUid,
    });
  }

  /// Nudge a DECIDED battle to finish once its 30s grace has elapsed. The server
  /// re-checks the buffer (so this can't end it early) and is idempotent, so any
  /// watcher can call it. Best-effort - failures are swallowed by the caller.
  Future<void> settleBattle(String matchId) async {
    await _functions
        .httpsCallable('settleMainStageBattle')
        .call<Map<String, dynamic>>({'matchId': matchId});
  }
}

/// The bracket slot a finalist is about to play - everything
/// [MainStageService.startBattle] needs. Carried through the pre-match camera
/// check so the battle is only CREATED once the player passes the check and
/// commits (a finals battle can't be requeued if the setup is bad).
@immutable
class MainStageStart {
  const MainStageStart({
    required this.tournamentId,
    required this.roundIdx,
    required this.matchIdx,
  });

  final String tournamentId;
  final int roundIdx;
  final int matchIdx;
}

/// The pairing for a Main Stage chess-clock battle - the two named
/// semifinalists in one channel, plus the clock config from the server.
class MainStageBattlePairing {
  const MainStageBattlePairing({
    required this.matchId,
    required this.channelName,
    required this.opponentId,
    required this.agoraUid,
    required this.turnMs,
    required this.interrupts,
    required this.shotClockMs,
    required this.graceMs,
  });

  final String matchId;
  final String channelName;
  final String opponentId;
  final int agoraUid; // 1 = player1 (the host), 2 = player2
  final int turnMs;
  final int interrupts;
  final int shotClockMs;
  final int graceMs; // interrupt grace window (ms); 0 = instant

  bool get isHost => agoraUid == 1;
}
