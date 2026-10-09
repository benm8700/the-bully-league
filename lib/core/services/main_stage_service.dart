import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Where the viewer stands in a Main Stage (weekly finals) tournament. Computed
/// purely from the tournament document + the viewer's uid, so the screen can
/// render the right state without a round-trip. Mirrors the server lifecycle in
/// functions/mainStageTournament.js + mainStageLifecycle.js.
enum MainStageRole { finalist, alternate, judge, none }

/// The viewer's invite answer, read from the doc's `invites` map.
enum InviteStatus { pending, accepted, declined, notInvited }

@immutable
class MainStageView {
  const MainStageView({
    required this.tournamentId,
    required this.status,
    required this.role,
    required this.invite,
    required this.isTopSeed,
    required this.field,
    required this.candidates,
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

  /// The locked field (seed order), empty until the 4pm lock.
  final List<String> field;

  /// The opponents the #1 may call out: the locked field minus themselves.
  /// Empty unless [isTopSeed] and the callout is open (status == locked).
  final List<String> candidates;

  bool get calloutOpen => isTopSeed && status == 'locked';
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

    return MainStageView(
      tournamentId: id,
      status: status,
      role: role,
      invite: invite,
      isTopSeed: isTopSeed,
      field: field,
      candidates: candidates,
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
  });

  final String matchId;
  final String channelName;
  final String opponentId;
  final int agoraUid; // 1 = player1 (the host), 2 = player2
  final int turnMs;
  final int interrupts;
  final int shotClockMs;

  bool get isHost => agoraUid == 1;
}
