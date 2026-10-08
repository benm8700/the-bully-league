import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../widgets/home_action_button.dart';

import '../../core/services/agora_spectator_service.dart';
import '../../core/services/spectator_service.dart';
import '../../widgets/follow_button.dart';
import '../../widgets/live_vote_panel.dart';
import '../profile/performer_profile_screen.dart';

/// Watching a live tournament battle.
///
/// The two players are stacked, which is the same arrangement the vertical
/// highlight render uses - and for the same reason. In roast content the
/// listener's reaction is frequently funnier than the line, so both faces
/// have to be on screen; side-by-side gives each of them a narrow strip on
/// a phone, and speaker-only framing throws away half the joke.
///
/// Talks only to [SpectatorService], never to Agora directly, so moving to
/// a CDN later is one implementation class rather than a rewrite of this
/// screen.
class LiveViewerScreen extends StatefulWidget {
  const LiveViewerScreen({
    super.key,
    required this.matchId,
    this.subtitle,
  });

  final String matchId;

  /// e.g. "Round 2" - context the viewer would otherwise have to remember.
  final String? subtitle;

  @override
  State<LiveViewerScreen> createState() => _LiveViewerScreenState();
}

class _LiveViewerScreenState extends State<LiveViewerScreen>
    with WidgetsBindingObserver {
  final SpectatorService _spectator = AgoraSpectatorService();
  bool _loading = true;

  /// True once we've left the Agora channel because the battle ended (or the
  /// app was backgrounded). Stops the match audio continuing to play after the
  /// live stream is over - the leak the live test hit.
  bool _watchStopped = false;
  String? _error;
  String? _player1Id;
  String? _player2Id;
  String _player1Name = 'Player 1';
  String _player2Name = 'Player 2';

  // The "N watching" crowd count. A heartbeat (my own doc, refreshed) plus a
  // live count of everyone with a fresh heartbeat - social proof for
  // spectators and, later, crowd energy for performers.
  Timer? _heartbeat;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _watchersSub;
  int _watchers = 0;

  CollectionReference<Map<String, dynamic>> get _viewers =>
      FirebaseFirestore.instance
          .collection('liveWatch')
          .doc(widget.matchId)
          .collection('viewers');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leave the Agora channel when the app is backgrounded, so the match audio
    // can never keep playing out of a phone (or the emulator) the viewer has
    // navigated away from.
    if (state != AppLifecycleState.resumed) {
      _spectator.stopWatching();
      _watchStopped = true;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat?.cancel();
    _watchersSub?.cancel();
    // Drop my heartbeat so the count falls promptly when I leave. Best-effort:
    // if it fails, the 30s freshness filter stops counting me anyway.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) _viewers.doc(uid).delete().catchError((_) {});
    // Fire and forget: State.dispose cannot await, and leaving the channel
    // is what stops Agora billing this viewer.
    _spectator.dispose();
    super.dispose();
  }

  /// Registers this viewer's heartbeat and starts counting the crowd.
  void _beginWatchCount() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    void beat() => _viewers
        .doc(uid)
        .set({'lastSeenMs': DateTime.now().millisecondsSinceEpoch});
    beat();
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) => beat());
    // Count only fresh heartbeats, so someone who closed the app without a
    // clean exit is not counted forever.
    _watchersSub = _viewers.snapshots().listen((snap) {
      final cutoff = DateTime.now().millisecondsSinceEpoch - 30000;
      final n = snap.docs.where((d) {
        final ts = d.data()['lastSeenMs'];
        return ts is num && ts > cutoff;
      }).length;
      if (mounted) setState(() => _watchers = n);
    });
  }

  Future<void> _start() async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('watchLiveMatch')
          .call<Map<String, dynamic>>({'matchId': widget.matchId});
      final data = result.data;
      await _spectator.initialize();
      await _spectator.watch(
        channelName: data['channelName'] as String,
        token: data['token'] as String,
        uid: (data['agoraUid'] as num).toInt(),
      );
      if (mounted) {
        setState(() {
          _loading = false;
          _player1Id = data['player1Id'] as String?;
          _player2Id = data['player2Id'] as String?;
          _player1Name = data['player1Name'] as String? ?? 'Player 1';
          _player2Name = data['player2Name'] as String? ?? 'Player 2';
        });
        _beginWatchCount();
      }
    } on FirebaseFunctionsException catch (e) {
      // The server's message is shown verbatim - it is the one that knows
      // whether this is a finished battle, a private match, or a
      // tournament that is not running.
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message ?? 'Could not watch that battle.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not connect to the battle.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Watching live'),
        // The crowd count - social proof that this is where the action is.
        // Shown once at least one heartbeat is in (always includes you).
        actions: [
          const HomeActionButton(),
          if (_watchers > 0)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.remove_red_eye, size: 16),
                  const SizedBox(width: 5),
                  Text('$_watchers watching',
                      style: Theme.of(context).textTheme.labelLarge),
                ],
              ),
            ),
        ],
        // Named so a viewer scrolling back knows which battle this is.
        bottom: widget.subtitle == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(20),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(widget.subtitle!,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
              ),
            )
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('matches')
                      .doc(widget.matchId)
                      .snapshots(),
                  builder: (context, snap) {
                    final completed =
                        snap.data?.data()?['status'] == 'completed';
                    final haveNames = _player1Id != null && _player2Id != null;
                    // The battle is over: leave the Agora channel (this is what
                    // stops the match audio - the leak the live test hit) and
                    // put the BALLOT front and centre, rather than a dead video
                    // feed and a "watch the clip" dead-end.
                    if (completed && !_watchStopped) {
                      _watchStopped = true;
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _spectator.stopWatching());
                    }
                    if (completed && haveNames) {
                      return Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                            child: Text(
                              'Battle finished - cast your vote',
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              child: LiveVotePanel(
                                matchId: widget.matchId,
                                player1Id: _player1Id!,
                                player2Id: _player2Id!,
                                player1Name: _player1Name,
                                player2Name: _player2Name,
                              ),
                            ),
                          ),
                        ],
                      );
                    }
                    // Live: the two video tiles, plus the vote panel (which
                    // renders nothing until the battle ends).
                    return Column(
                      children: [
                        Expanded(
                          child: ValueListenableBuilder<String?>(
                            valueListenable: _spectator.failure,
                            builder: (context, failure, _) {
                              // A rejected or expired token is otherwise
                              // indistinguishable from two players who have
                              // not started - both are a screen that says
                              // "waiting" forever.
                              if (failure != null) {
                                return Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Text(failure,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                            color: Colors.white70)),
                                  ),
                                );
                              }
                              return ValueListenableBuilder<Set<int>>(
                                valueListenable: _spectator.presentUids,
                                builder: (context, present, _) => Column(
                                  children: [
                                    Expanded(
                                        child: _tile(1, present, _player1Id,
                                            _player1Name)),
                                    const SizedBox(height: 2),
                                    Expanded(
                                        child: _tile(2, present, _player2Id,
                                            _player2Name)),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        if (haveNames)
                          LiveVotePanel(
                            matchId: widget.matchId,
                            player1Id: _player1Id!,
                            player2Id: _player2Id!,
                            player1Name: _player1Name,
                            player2Name: _player2Name,
                          ),
                      ],
                    );
                  },
                ),
    );
  }

  Widget _tile(
      int playerUid, Set<int> present, String? playerId, String playerName) {
    final view = _spectator.playerVideo(playerUid) ??
        ColoredBox(
          color: const Color(0xFF111111),
          child: Center(
            child: Text(
              // A player whose stream has not arrived gets an honest
              // placeholder rather than a black rectangle that reads as a
              // broken app.
              present.isEmpty
                  ? 'Waiting for the battle to start...'
                  : 'Waiting for player $playerUid...',
              style: const TextStyle(color: Colors.white38),
            ),
          ),
        );
    return Stack(
      fit: StackFit.expand,
      children: [
        view,
        // Name + Follow, so the crowd can back a performer they like right
        // from the live battle - the moment a follow is most earned. The
        // tag names who they are watching; the button hides itself for your
        // own battle.
        Positioned(
          top: 8,
          left: 8,
          child: _PerformerTag(uid: playerId, name: playerName),
        ),
      ],
    );
  }
}

/// A small overlay over a live performer's tile: their name (tap for their
/// fame page) plus a compact Follow button.
class _PerformerTag extends StatelessWidget {
  const _PerformerTag({required this.uid, required this.name});

  final String? uid;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: uid == null
                ? null
                : () => PerformerProfileScreen.open(context, uid!,
                    username: name),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                name,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13),
              ),
            ),
          ),
        ),
        if (uid != null) ...[
          const SizedBox(width: 6),
          FollowButton(uid: uid!, compact: true),
        ],
      ],
    );
  }
}
