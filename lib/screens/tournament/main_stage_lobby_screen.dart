import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/main_stage_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/lobby_chat.dart';
import 'live_viewer_screen.dart';

/// The Main Stage VIEWERS' LOBBY - a holding room where the audience gathers to
/// watch the show. Shows a live "N watching" count, the crowd chat, and a clear
/// way into the battle on stage (or a "next battle is being set up" note between
/// battles). This is where it's obvious you go to watch.
///
/// Presence is a heartbeat: each viewer writes its own doc under
/// mainStageLobby/{tournamentId}/viewers every 15s and deletes it on leave; the
/// count is the distinct docs seen in the last 30s (a crashed client ages out).
class MainStageLobbyScreen extends StatefulWidget {
  const MainStageLobbyScreen({super.key, required this.tournamentId});

  final String tournamentId;

  @override
  State<MainStageLobbyScreen> createState() => _MainStageLobbyScreenState();
}

class _MainStageLobbyScreenState extends State<MainStageLobbyScreen>
    with WidgetsBindingObserver {
  static const _staleMs = 30 * 1000;

  final _db = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final _mainStage = MainStageService();
  Timer? _heartbeat;

  DocumentReference<Map<String, dynamic>> get _meRef => _db
      .collection('mainStageLobby')
      .doc(widget.tournamentId)
      .collection('viewers')
      .doc(_uid);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _beat();
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) => _beat());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _beat();
    } else {
      // Drop out of the count while backgrounded.
      _meRef.delete().catchError((_) {});
    }
  }

  void _beat() {
    if (_uid.isEmpty) return;
    _meRef.set({'lastSeenMs': DateTime.now().millisecondsSinceEpoch}).catchError(
        (_) {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat?.cancel();
    _meRef.delete().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('The Crowd'),
        backgroundColor: Colors.black,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _watchingCount(),
              const SizedBox(height: 10),
              _watchCta(),
              const SizedBox(height: 12),
              Expanded(
                child: LobbyChat(
                  tournamentId: widget.tournamentId,
                  expand: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Live "N watching now" from the heartbeat docs (distinct, seen in 30s).
  Widget _watchingCount() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _db
          .collection('mainStageLobby')
          .doc(widget.tournamentId)
          .collection('viewers')
          .snapshots(),
      builder: (context, snap) {
        final now = DateTime.now().millisecondsSinceEpoch;
        var n = 0;
        for (final d in snap.data?.docs ?? const []) {
          final seen = (d.data()['lastSeenMs'] as num?)?.toInt() ?? 0;
          if (now - seen < _staleMs) n++;
        }
        final pink = context.palette.live;
        return Row(
          children: [
            Icon(Icons.visibility, color: pink, size: 20),
            const SizedBox(width: 8),
            Text(
              n <= 1 ? 'You\'re here' : '$n watching now',
              style: TextStyle(
                  color: pink, fontWeight: FontWeight.w800, fontSize: 16),
            ),
          ],
        );
      },
    );
  }

  /// Into the battle on stage, or a "next one's coming" note between battles.
  Widget _watchCta() {
    return StreamBuilder<MainStageView?>(
      stream: _mainStage.watch(),
      builder: (context, snap) {
        final v = snap.data;
        final mid = (v != null && v.status == 'live') ? v.liveBattleMatchId
            : null;
        if (mid == null) {
          return Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Colors.white.withValues(alpha: 0.05),
              border: Border.all(color: Colors.white12),
            ),
            child: const Row(
              children: [
                Icon(Icons.hourglass_top, color: Colors.white54, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'The next battle is being set up — hang out here, it starts soon.',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ],
            ),
          );
        }
        return SizedBox(
          height: 52,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: context.palette.live,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.sensors),
            label: const Text('Watch the battle on stage'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => LiveViewerScreen(matchId: mid)),
            ),
          ),
        );
      },
    );
  }
}
