import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../core/judges_table.dart';
import '../core/services/agora_token_service.dart';
import '../core/services/main_stage_service.dart';
import '../core/services/panel_video_service.dart';
import '../theme/app_theme.dart';
import '../theme/house_theme.dart';
import 'judges_table.dart';

/// A seated JUDGE's view of the judges' table during the debate.
///
/// The judge goes ON CAMERA (PanelVideoService, a broadcaster on
/// `judges_<matchId>`), sees the other judges, and casts their one real public
/// vote for a battler. Self-contained - mounted by JudgesRoomScreen only in the
/// debate phase (battle over, verdict not yet in); it owns its engine and tears
/// it down on dispose. The crowd equivalent is CrowdJudgesTable (audience).
class JudgePanelView extends StatefulWidget {
  const JudgePanelView({
    super.key,
    required this.matchId,
    required this.tournamentId,
    required this.myUid,
    required this.player1Id,
    required this.player2Id,
    required this.player1Name,
    required this.player2Name,
    this.winnerId,
    this.decidedAtMs,
    this.service,
  });

  final String matchId;
  final String tournamentId;
  final String myUid;
  final String player1Id;
  final String player2Id;
  final String player1Name;
  final String player2Name;

  /// Set once the panel has DECIDED (the verdict is locked); null during the
  /// debate. While set, voting is closed and the 30s grace countdown runs.
  final String? winnerId;

  /// When the verdict was decided (ms), for the grace countdown + auto-settle.
  final int? decidedAtMs;
  final MainStageService? service;

  @override
  State<JudgePanelView> createState() => _JudgePanelViewState();
}

class _JudgePanelViewState extends State<JudgePanelView> {
  late final MainStageService _service = widget.service ?? MainStageService();
  final PanelVideoService _panel = PanelVideoService();

  List<String> _judges = [];
  String? _headJudge;
  Map<String, String> _judgeNames = {};
  bool _ready = false;
  String? _error;

  bool _submitting = false;
  String? _voteError;

  // Once decided, a 30s grace runs (cameras stay live, judges keep talking),
  // then this nudges the server to settle. The 1s tick drives the countdown.
  bool _settleCalled = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _maybeSettle();
      setState(() {});
    });
    _join();
  }

  Future<void> _join() async {
    try {
      final db = FirebaseFirestore.instance;
      final t = await db.collection('tournaments').doc(widget.tournamentId).get();
      _judges = (t.data()?['judges'] as List? ?? const [])
          .whereType<String>()
          .toList();
      final handPicked = (t.data()?['handPickedJudges'] as List? ?? const [])
          .whereType<String>()
          .toList();
      _headJudge = handPicked.firstWhere(_judges.contains, orElse: () => '');
      if (_headJudge!.isEmpty) _headJudge = null;

      final myIndex = _judges.indexOf(widget.myUid);
      if (myIndex < 0) {
        setState(() {
          _error = "You aren't seated on this panel.";
        });
        return;
      }
      final seatUid = kJudgeSeatUidBase + myIndex;
      final token = await fetchAgoraToken('judges_${widget.matchId}');
      await _panel.initialize();
      await _panel.join(
        channelName: 'judges_${widget.matchId}',
        token: token,
        uid: seatUid,
      );

      // Start the debate recording (best-effort). The server claims it
      // race-safely, so only one of the judges' calls actually records, and the
      // watchdog stops it when the verdict lands - so this is fire-and-forget.
      unawaited(FirebaseFunctions.instance
          .httpsCallable('startDebateRecording')
          .call<Map<String, dynamic>>({'matchId': widget.matchId})
          .then((_) {}, onError: (_) {}));

      final names = <String, String>{};
      for (final id in _judges) {
        final u = await db.collection('users').doc(id).get();
        names[id] = (u.data()?['username'] as String?) ?? 'Judge';
      }

      if (!mounted) return;
      setState(() {
        _judgeNames = names;
        _ready = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = "Couldn't join the judges' table.");
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _panel.dispose();
    super.dispose();
  }

  /// Seconds left in the post-decision grace (cameras keep rolling), or null if
  /// the panel hasn't decided yet. 30s to match the server buffer.
  int? _graceLeft() {
    final d = widget.decidedAtMs;
    if (widget.winnerId == null || d == null) return null;
    final remMs = d + 30 * 1000 - DateTime.now().millisecondsSinceEpoch;
    return remMs <= 0 ? 0 : (remMs / 1000).ceil();
  }

  /// Once the grace has run out, nudge the server to finish the battle (apply
  /// Elo, advance the bracket, stop the cameras). Idempotent + server-rechecked,
  /// and called at most once per view.
  void _maybeSettle() {
    if (_settleCalled || widget.winnerId == null) return;
    final left = _graceLeft();
    if (left == null || left > 0) return;
    _settleCalled = true;
    _service.settleBattle(widget.matchId).catchError((_) {});
  }

  Future<void> _vote(String winnerUid) async {
    setState(() {
      _submitting = true;
      _voteError = null;
    });
    try {
      await _service.castJudgeVote(widget.matchId, winnerUid);
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => _voteError = e.message ?? "Couldn't record that.");
    } catch (_) {
      if (mounted) setState(() => _voteError = "Couldn't record that - try again.");
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70)),
        ),
      );
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('matches')
          .doc(widget.matchId)
          .collection('mainStageVotes')
          .snapshots(),
      builder: (context, snap) {
        final votes = <String, String>{};
        String? myPick;
        for (final d in snap.data?.docs ?? const []) {
          final w = d.data()['winnerUid'];
          if (w is String) {
            votes[d.id] = w;
            if (d.id == widget.myUid) myPick = w;
          }
        }
        final seats = buildJudgeSeats(
          panel: _judges,
          headJudge: _headJudge,
          myUid: widget.myUid,
          seatUidBase: kJudgeSeatUidBase,
          votes: votes,
        );
        return ValueListenableBuilder<Set<int>>(
          valueListenable: _panel.presentUids,
          builder: (context, present, _) => Column(
            children: [
              Expanded(
                child: ValueListenableBuilder<int?>(
                  valueListenable: _panel.activeSpeaker,
                  builder: (context, active, _) => JudgesTable(
                    seats: seats,
                    present: present,
                    activeSeatUid: active,
                    judgeNames: _judgeNames,
                    playerNames: {
                      widget.player1Id: widget.player1Name,
                      widget.player2Id: widget.player2Name,
                    },
                    playerColors: {
                      widget.player1Id: House.gelRed,
                      widget.player2Id: House.gelBlue,
                    },
                    localViewBuilder: _panel.localVideoView,
                    remoteViewBuilder: _panel.remoteVideoView,
                  ),
                ),
              ),
              _voteBar(myPick),
            ],
          ),
        );
      },
    );
  }

  /// Transparent vote control at the very bottom - no boxed panel, so the
  /// cameras own the screen. Two tap-to-vote buttons; tapping casts (or
  /// changes) the vote immediately - no separate confirm, since a vote is
  /// changeable until the panel settles and the colour already shows your pick.
  Widget _voteBar(String? myPick) {
    final bottom = 8 + MediaQuery.of(context).padding.bottom;
    // DECIDED: the verdict is locked, so swap the buttons for the result + the
    // 30s grace - the judges stay on camera and keep talking before it ends.
    if (widget.winnerId != null) {
      final left = _graceLeft() ?? 0;
      final name = widget.winnerId == widget.player1Id
          ? widget.player1Name
          : widget.player2Name;
      return Padding(
        padding: EdgeInsets.fromLTRB(12, 6, 12, bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$name takes it',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: context.palette.reward,
                    fontWeight: FontWeight.w800,
                    fontSize: 16)),
            const SizedBox(height: 2),
            Text(
              left > 0 ? 'Wrapping up in ${left}s' : 'Wrapping up…',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      );
    }
    // Open vote: two transparent tap-to-vote buttons.
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 4, 12, bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_voteError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(_voteError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.palette.live, fontSize: 11)),
            ),
          Row(children: [
            Expanded(child: _voteButton(
                widget.player1Id, widget.player1Name, House.gelRed, myPick)),
            const SizedBox(width: 10),
            Expanded(child: _voteButton(
                widget.player2Id, widget.player2Name, House.gelBlue, myPick)),
          ]),
        ],
      ),
    );
  }

  Widget _voteButton(String id, String name, Color color, String? myPick) {
    final selected = myPick == id;
    return OutlinedButton(
      onPressed: _submitting ? null : () => _vote(id),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 10),
        backgroundColor:
            selected ? color.withValues(alpha: 0.28) : Colors.transparent,
        side: BorderSide(
            color: selected ? Colors.white : color, width: selected ? 2 : 1),
      ),
      child: Text(name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700)),
    );
  }
}
