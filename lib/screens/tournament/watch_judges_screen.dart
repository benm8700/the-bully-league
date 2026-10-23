import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/house_theme.dart';
import '../../widgets/crowd_judges_table.dart';

/// Straight to the JUDGES' TABLE for a finished battle - the one-tap "watch the
/// panel decide it" view. Deliberately NOT the spectator LiveViewerScreen:
/// that joins the battle video (which a battler can't watch on their OWN match,
/// and which is pointless once the battle is over). This reads the match doc
/// directly and mounts [CrowdJudgesTable] (watchJudgesTable, which allows
/// participants), so a finalist can watch their own verdict land.
class WatchJudgesScreen extends StatefulWidget {
  const WatchJudgesScreen({super.key, required this.matchId});

  final String matchId;

  @override
  State<WatchJudgesScreen> createState() => _WatchJudgesScreenState();
}

class _WatchJudgesScreenState extends State<WatchJudgesScreen> {
  bool _loading = true;
  String? _error;
  String? _p1Id;
  String? _p2Id;
  String _p1Name = 'Player 1';
  String _p2Name = 'Player 2';

  DocumentReference<Map<String, dynamic>> get _matchRef =>
      FirebaseFirestore.instance.collection('matches').doc(widget.matchId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final db = FirebaseFirestore.instance;
      final m = (await _matchRef.get()).data();
      if (m == null || m['mainStage'] == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = "That battle isn't available.";
          });
        }
        return;
      }
      _p1Id = m['player1Id'] as String?;
      _p2Id = m['player2Id'] as String?;
      Future<String?> nameOf(String? uid) async {
        if (uid == null) return null;
        try {
          return (await db.collection('users').doc(uid).get())
              .data()?['username'] as String?;
        } catch (_) {
          return null;
        }
      }

      final names = await Future.wait([nameOf(_p1Id), nameOf(_p2Id)]);
      _p1Name = names[0] ?? 'Player 1';
      _p2Name = names[1] ?? 'Player 2';
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Couldn't open the judges' table.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('The verdict'),
        backgroundColor: Colors.black,
      ),
      body: _error != null
          ? _centered(_error!)
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _body(),
    );
  }

  Widget _body() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _matchRef.snapshots(),
      builder: (context, snap) {
        final m = snap.data?.data();
        final settled = m?['voteFinalized'] == true;
        final winnerId = m?['judgeWinnerId'] as String?;
        if (settled && winnerId != null) {
          final name = winnerId == _p1Id
              ? _p1Name
              : winnerId == _p2Id
                  ? _p2Name
                  : null;
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.emoji_events,
                      size: 56, color: context.palette.reward),
                  const SizedBox(height: 12),
                  Text(name == null ? 'The judges have decided.' : '$name takes it.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: Colors.white, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          );
        }
        if (_p1Id == null || _p2Id == null) {
          return _centered("That battle isn't available.");
        }
        // The debate: the judges' table, votes landing live.
        return CrowdJudgesTable(
          matchId: widget.matchId,
          playerNames: {_p1Id!: _p1Name, _p2Id!: _p2Name},
          playerColors: {_p1Id!: House.gelRed, _p2Id!: House.gelBlue},
        );
      },
    );
  }

  Widget _centered(String s) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(s,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70)),
        ),
      );
}
