import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../core/judges_table.dart';
import '../core/services/agora_spectator_service.dart';
import 'judges_table.dart';

/// The CROWD's view of the Main Stage judges' table during the debate.
///
/// Joins the `judges_<matchId>` channel as audience (via watchJudgesTable, a
/// subscriber token) and renders the shared [JudgesTable] with each judge's
/// vote landing live. Self-contained so the viewer screen just mounts it in the
/// debate branch; it owns its Agora engine and tears it down on dispose.
class CrowdJudgesTable extends StatefulWidget {
  const CrowdJudgesTable({
    super.key,
    required this.matchId,
    required this.playerNames,
    required this.playerColors,
  });

  final String matchId;

  /// playerId -> name, for the vote badges + the tally.
  final Map<String, String> playerNames;

  /// playerId -> the battler's gel colour (red/blue), for the vote treatment.
  final Map<String, Color> playerColors;

  @override
  State<CrowdJudgesTable> createState() => _CrowdJudgesTableState();
}

class _CrowdJudgesTableState extends State<CrowdJudgesTable> {
  final AgoraSpectatorService _spectator = AgoraSpectatorService();
  List<String> _panel = [];
  String? _headJudge;
  int _seatBase = 11;
  Map<String, String> _judgeNames = {};
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _join();
  }

  Future<void> _join() async {
    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('watchJudgesTable')
          .call<Map<String, dynamic>>({'matchId': widget.matchId});
      final d = Map<String, dynamic>.from(res.data as Map);
      _panel = (d['judges'] as List? ?? const []).whereType<String>().toList();
      _headJudge = d['headJudge'] as String?;
      _seatBase = (d['seatUidBase'] as num?)?.toInt() ?? 11;

      await _spectator.initialize();
      await _spectator.watch(
        channelName: d['channelName'] as String,
        token: d['token'] as String,
        uid: (d['agoraUid'] as num).toInt(),
      );

      final names = <String, String>{};
      for (final id in _panel) {
        final u = await FirebaseFirestore.instance
            .collection('users')
            .doc(id)
            .get();
        names[id] = (u.data()?['username'] as String?) ?? 'Judge';
      }
      if (!mounted) return;
      setState(() {
        _judgeNames = names;
        _ready = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not join the judges\' table.');
    }
  }

  @override
  void dispose() {
    _spectator.dispose();
    super.dispose();
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
    if (!_ready) {
      return const Center(child: CircularProgressIndicator());
    }
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('matches')
          .doc(widget.matchId)
          .collection('mainStageVotes')
          .snapshots(),
      builder: (context, snap) {
        final votes = <String, String>{
          for (final d in snap.data?.docs ?? const [])
            if (d.data()['winnerUid'] is String)
              d.id: d.data()['winnerUid'] as String,
        };
        final seats = buildJudgeSeats(
          panel: _panel,
          headJudge: _headJudge,
          seatUidBase: _seatBase,
          votes: votes,
        );
        return ValueListenableBuilder<Set<int>>(
          valueListenable: _spectator.presentUids,
          builder: (context, present, _) => ValueListenableBuilder<int?>(
            valueListenable: _spectator.activeSpeaker,
            builder: (context, active, _) => JudgesTable(
              seats: seats,
              present: present,
              activeSeatUid: active,
              judgeNames: _judgeNames,
              playerNames: widget.playerNames,
              playerColors: widget.playerColors,
              remoteViewBuilder: (uid) => _spectator.playerVideo(uid),
            ),
          ),
        );
      },
    );
  }
}
