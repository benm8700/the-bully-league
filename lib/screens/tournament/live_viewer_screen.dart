import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../core/services/agora_spectator_service.dart';
import '../../core/services/spectator_service.dart';
import '../../widgets/live_vote_panel.dart';

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

class _LiveViewerScreenState extends State<LiveViewerScreen> {
  final SpectatorService _spectator = AgoraSpectatorService();
  bool _loading = true;
  String? _error;
  String? _player1Id;
  String? _player2Id;
  String _player1Name = 'Player 1';
  String _player2Name = 'Player 2';

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    // Fire and forget: State.dispose cannot await, and leaving the channel
    // is what stops Agora billing this viewer.
    _spectator.dispose();
    super.dispose();
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
              : Column(
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
                                // Players publish as fixed uids 1 and 2,
                                // assigned server-side at pairing, so the
                                // layout never has to negotiate who is
                                // who.
                                Expanded(child: _tile(1, present)),
                                const SizedBox(height: 2),
                                Expanded(child: _tile(2, present)),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    // Renders nothing until the battle ends, then becomes
                    // the ballot, then the count, then the verdict.
                    if (_player1Id != null && _player2Id != null)
                      LiveVotePanel(
                        matchId: widget.matchId,
                        player1Id: _player1Id!,
                        player2Id: _player2Id!,
                        player1Name: _player1Name,
                        player2Name: _player2Name,
                      ),
                  ],
                ),
    );
  }

  Widget _tile(int playerUid, Set<int> present) {
    final view = _spectator.playerVideo(playerUid);
    if (view != null) return view;
    // A player whose stream has not arrived gets an honest placeholder
    // rather than a black rectangle that reads as a broken app.
    return ColoredBox(
      color: const Color(0xFF111111),
      child: Center(
        child: Text(
          present.isEmpty ? 'Waiting for the battle to start...'
              : 'Waiting for player $playerUid...',
          style: const TextStyle(color: Colors.white38),
        ),
      ),
    );
  }
}
