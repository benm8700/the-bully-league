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
    this.service,
  });

  final String matchId;
  final String tournamentId;
  final String myUid;
  final String player1Id;
  final String player2Id;
  final String player1Name;
  final String player2Name;
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
  String? _selected; // tapped-but-not-confirmed battler

  @override
  void initState() {
    super.initState();
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
    _panel.dispose();
    super.dispose();
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
                child: JudgesTable(
                  seats: seats,
                  present: present,
                  judgeNames: _judgeNames,
                  playerNames: {
                    widget.player1Id: widget.player1Name,
                    widget.player2Id: widget.player2Name,
                  },
                  localViewBuilder: _panel.localVideoView,
                  remoteViewBuilder: _panel.remoteVideoView,
                ),
              ),
              _voteBar(myPick),
            ],
          ),
        );
      },
    );
  }

  Widget _voteBar(String? myPick) {
    final sel = _selected;
    final canConfirm = sel != null && sel != myPick && !_submitting;
    return Container(
      width: double.infinity,
      color: const Color(0xFF151515),
      padding: EdgeInsets.fromLTRB(
          14, 10, 14, 10 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Your verdict',
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: Colors.white70)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _pickChip(widget.player1Id, widget.player1Name,
                House.gelRed, myPick)),
            const SizedBox(width: 10),
            Expanded(child: _pickChip(widget.player2Id, widget.player2Name,
                House.gelBlue, myPick)),
          ]),
          if (_voteError != null) ...[
            const SizedBox(height: 6),
            Text(_voteError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.palette.live, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          if (canConfirm)
            FilledButton(
              onPressed: () => _vote(sel),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                backgroundColor: _colorOf(sel),
                foregroundColor: Colors.white,
              ),
              child: _submitting
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(myPick == null
                      ? 'Vote for ${_nameOf(sel)}'
                      : 'Change to ${_nameOf(sel)}'),
            )
          else if (myPick != null)
            Text('You voted for ${_nameOf(myPick)} - tap the other to change',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12))
          else
            const Text('Tap the winner, then confirm.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _pickChip(String id, String name, Color color, String? myPick) {
    final selected = (_selected ?? myPick) == id;
    return OutlinedButton(
      onPressed: _submitting ? null : () => setState(() => _selected = id),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12),
        backgroundColor: selected ? color.withValues(alpha: 0.22) : null,
        side: BorderSide(color: selected ? Colors.white : color, width: selected ? 2 : 1),
      ),
      child: Text(name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
    );
  }

  String _nameOf(String id) => id == widget.player1Id ? widget.player1Name
      : id == widget.player2Id ? widget.player2Name : 'them';
  Color _colorOf(String id) => id == widget.player1Id ? House.gelRed : House.gelBlue;
}
