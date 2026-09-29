import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../widgets/emoji_rate_row.dart';
import '../../widgets/live_tally.dart';
import '../../widgets/match_clip_player.dart';
import '../../widgets/turnstile_challenge.dart';
import '../moderation/report_screen.dart';

/// Community voting (Build Order step 5). CAPTCHA gate, 24h window,
/// one-vote-per-account and account-age vote-weight are all enforced
/// server-side in the castVote Cloud Function (functions/index.js) - this
/// screen never writes a ballot directly.
///
/// The running score is deliberately NOT shown until your ballot is in.
/// Seeing who is ahead before you judge biases the judgement, and it would
/// tell anyone rallying support exactly how many more votes they need.
/// Once you have voted there is nothing left to bias, so the scoreboard
/// opens up and stays live - that reveal is also the reward for voting.
/// The rule is enforced in firestore.rules, not here; this screen only
/// decides what to render.
class VoteScreen extends StatefulWidget {
  const VoteScreen({super.key, required this.matchId, this.videoUrl});

  final String matchId;

  /// The highlight clip to judge, when one has been published. Passed in
  /// from the queue so this screen doesn't refetch what the caller
  /// already knows; null renders an honest 'not available yet' state.
  final String? videoUrl;

  @override
  State<VoteScreen> createState() => _VoteScreenState();
}

class _VoteScreenState extends State<VoteScreen> {
  /// The vote button stays locked until the clip has actually played for
  /// a few seconds.
  ///
  /// WHAT THIS IS AND IS NOT. It is not a security boundary - a modified
  /// client skips it in a line, and `castVote` enforces a minimum interval
  /// between votes server-side for exactly that reason. It is a PRICE ON
  /// SPEED. The whole farming exploit is that a careless vote takes two
  /// seconds and an honest one takes thirty; this closes most of that gap
  /// and costs an honest judge nothing, because they were watching anyway.
  ///
  /// Deliberately short. The goal is not to make someone watch a whole
  /// battle before forming a view - people decide fast and that is fine -
  /// it is to stop a vote being cheaper than a glance.
  static const kWatchSecondsBeforeVote = 12;

  bool _watchedEnough = false;

  /// The single overall winner the judge picked, by tapping that player's
  /// half of the stacked clip. The match goes to whoever gets the most
  /// winner votes. (This replaced per-round voting - the developer's call:
  /// tapping a player's video box to pick the winner, nothing overlaying and
  /// blocking the players.)
  String? _selectedWinner;

  /// The emoji rating the judge gives each player (required to submit) - the
  /// audience-feedback ecosystem that replaced the funniest-round mark.
  String? _emojiP1;
  String? _emojiP2;
  String? _turnstileToken;
  bool _submitting = false;
  String? _errorMessage;

  /// Flipped locally the moment a vote lands, so the scoreboard appears
  /// immediately rather than waiting on the ballot document to round-trip.
  bool _justVoted = false;

  Future<void> _submitVote(String player1Id, String player2Id) async {
    if (_selectedWinner == null ||
        _turnstileToken == null ||
        _emojiP1 == null ||
        _emojiP2 == null) {
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final callable = FirebaseFunctions.instance.httpsCallable('castVote');
      await callable.call({
        'matchId': widget.matchId,
        // A single overall winner. castVote normalises this into its
        // per-round tally server-side, so nothing downstream changes.
        'votedForPlayerId': _selectedWinner,
        // Required per-player emoji ratings.
        'emojiRatings': {player1Id: _emojiP1, player2Id: _emojiP2},
        'turnstileToken': _turnstileToken,
      });
      if (!mounted) return;
      setState(() => _justVoted = true);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Vote failed: ${e.message ?? e.code}');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    final matchRef =
        FirebaseFirestore.instance.collection('matches').doc(widget.matchId);
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('Judge this battle')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: matchRef.snapshots(),
        builder: (context, matchSnap) {
          if (matchSnap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!matchSnap.hasData || !matchSnap.data!.exists) {
            return const Center(child: Text('Match not found.'));
          }
          final match = matchSnap.data!.data()!;
          final player1Id = match['player1Id'] as String;
          final player2Id = match['player2Id'] as String;
          final isParticipant = myUid == player1Id || myUid == player2Id;
          final closesAtMs = _closesAtMs(match);
          final roundCount =
              (((match['settings'] as Map?)?['roundCount'] as num?)?.toInt() ?? 3)
                  .clamp(1, 12);

          return FutureBuilder<List<String>>(
            future: _usernames(player1Id, player2Id),
            builder: (context, nameSnap) {
              final names = nameSnap.data ?? const ['Player 1', 'Player 2'];
              return _body(
                context: context,
                myUid: myUid,
                player1Id: player1Id,
                player2Id: player2Id,
                player1Name: names[0],
                player2Name: names[1],
                isParticipant: isParticipant,
                closesAtMs: closesAtMs,
                roundCount: roundCount,
              );
            },
          );
        },
      ),
    );
  }

  Widget _body({
    required BuildContext context,
    required String? myUid,
    required String player1Id,
    required String player2Id,
    required String player1Name,
    required String player2Name,
    required bool isParticipant,
    required int? closesAtMs,
    required int roundCount,
  }) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      // Your own ballot, which is the only one any client may read. Its
      // existence is what decides whether the scoreboard is unlocked.
      stream: myUid == null
          ? const Stream.empty()
          : FirebaseFirestore.instance
              .collection('votes')
              .doc(widget.matchId)
              .collection('ballots')
              .doc(myUid)
              .snapshots(),
      builder: (context, ballotSnap) {
        final alreadyVoted = _justVoted || (ballotSnap.data?.exists ?? false);
        final canVote = !isParticipant && !alreadyVoted;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The clip comes first, always. Judging without watching is
              // not judging. It's HEIGHT-CAPPED (a 9:16 clip at full width is
              // taller than the screen, which is what pushed the old vote
              // buttons off-screen), and in "pick a winner" mode the two
              // halves of the stacked clip ARE the vote: tap the top player
              // or the bottom player. The green outline shows your pick and
              // nothing overlays the faces.
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.55,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: MatchClipPlayer(
                      videoUrl: widget.videoUrl,
                      watchSecondsRequired: kWatchSecondsBeforeVote,
                      onWatchedEnough: () {
                        if (mounted) setState(() => _watchedEnough = true);
                      },
                      onSelectTop: canVote
                          ? () => setState(() => _selectedWinner = player1Id)
                          : null,
                      onSelectBottom: canVote
                          ? () => setState(() => _selectedWinner = player2Id)
                          : null,
                      selectedRegion: _selectedWinner == player1Id
                          ? ClipSelectRegion.top
                          : _selectedWinner == player2Id
                              ? ClipSelectRegion.bottom
                              : ClipSelectRegion.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (canVote) ...[
                Text(
                  _selectedWinner == null
                      ? 'Who won? Tap a roaster.'
                      : 'Your pick: '
                          '${_selectedWinner == player1Id ? player1Name : player2Name}',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  'Tap the top or bottom video to pick the funnier roaster. '
                  'Tap the other to switch.',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (_selectedWinner != null) ...[
                  Text('Now rate both:',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  EmojiRateRow(
                    name: player1Name,
                    selected: _emojiP1,
                    dark: false,
                    onSelect: (k) => setState(() => _emojiP1 = k),
                  ),
                  const SizedBox(height: 8),
                  EmojiRateRow(
                    name: player2Name,
                    selected: _emojiP2,
                    dark: false,
                    onSelect: (k) => setState(() => _emojiP2 = k),
                  ),
                  const SizedBox(height: 12),
                ],
                TurnstileChallenge(
                    onToken: (token) => setState(() => _turnstileToken = token)),
                const SizedBox(height: 16),
                if (!_watchedEnough) ...[
                  Text(
                    'Watch a bit of it first.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                ] else if (_selectedWinner == null) ...[
                  Text(
                    'Tap a roaster to pick the winner.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                ],
                FilledButton(
                  onPressed: (_selectedWinner != null &&
                          _turnstileToken != null &&
                          _watchedEnough &&
                          _emojiP1 != null &&
                          _emojiP2 != null &&
                          !_submitting)
                      ? () => _submitVote(player1Id, player2Id)
                      : null,
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Cast Vote'),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(_errorMessage!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 20),
                Text(
                  'The score is hidden until you vote, so nobody judges a '
                  'battle by who is already winning.',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ] else ...[
                Text(
                  isParticipant
                      ? 'Your battle, live'
                      : 'Judged. Here is how it stands.',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                if (isParticipant) ...[
                  const SizedBox(height: 6),
                  Text(
                    'You can\'t judge your own battle - the crowd decides '
                    'this one.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 16),
                LiveTally(
                  matchId: widget.matchId,
                  player1Name: player1Name,
                  player2Name: player2Name,
                  closesAtMs: closesAtMs,
                ),
              ],
              const SizedBox(height: 16),
              // Reporting stays available even for match participants (unlike
              // voting) - the report categories are about things outside the
              // roast format itself. But it is deliberately QUIET: a small ⋮
              // menu rather than two prominent "Report" buttons, so people are
              // not trigger-happy when they simply dislike a roaster
              // (developer's call, 2026-09-29). Apple 1.2 needs it findable,
              // not front-and-centre.
              Align(
                alignment: Alignment.centerRight,
                child: PopupMenuButton<int>(
                  icon: const Icon(Icons.more_vert, size: 20),
                  tooltip: 'More',
                  onSelected: (p) => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ReportScreen(
                          reportedUserId: p == 1 ? player1Id : player2Id,
                          matchId: widget.matchId),
                    ),
                  ),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 1, child: Text('Report $player1Name')),
                    PopupMenuItem(value: 2, child: Text('Report $player2Name')),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The 24h vote window runs from match COMPLETION, falling back to
  /// creation for a match that never completed - mirroring
  /// voteWindowStartMs in functions/matchFinalization.js exactly, so the
  /// countdown shown here is the one actually enforced by castVote.
  int? _closesAtMs(Map<String, dynamic> match) {
    final start = match['completedAt'] ?? match['createdAt'];
    if (start is! Timestamp) return null;
    return start.millisecondsSinceEpoch + 24 * 60 * 60 * 1000;
  }

  Future<List<String>> _usernames(String player1Id, String player2Id) async {
    final db = FirebaseFirestore.instance;
    final snaps = await Future.wait([
      db.collection('users').doc(player1Id).get(),
      db.collection('users').doc(player2Id).get(),
    ]);
    return [
      (snaps[0].data()?['username'] as String?) ?? 'Player 1',
      (snaps[1].data()?['username'] as String?) ?? 'Player 2',
    ];
  }
}

