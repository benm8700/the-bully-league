import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../widgets/admin_only.dart';
import '../../widgets/live_checkin.dart';
import '../../widgets/watch_live_list.dart';
import 'climb_screen.dart';
import '../match/pre_match_screen.dart';
import '../match/recording_consent_screen.dart';
import 'tournament_lobby_screen.dart';

class TournamentDetailScreen extends StatefulWidget {
  const TournamentDetailScreen({super.key, required this.tournamentId});

  final String tournamentId;

  @override
  State<TournamentDetailScreen> createState() => _TournamentDetailScreenState();
}

class _TournamentDetailScreenState extends State<TournamentDetailScreen> {
  /// The arena art, shown as a DIM light-touch wash only at the top of this
  /// screen, fading fast to near-black - a restrained echo of the full Home
  /// hero and the My Tournaments list, not a fourth full wallpaper.
  static const _detailBgAsset = 'assets/home/tournament_background.png';

  bool _busy = false;
  String? _statusMessage;

  /// Whether this player has already given recording consent for this
  /// tournament this session, so joining and each subsequent battle don't
  /// re-prompt.
  bool _consented = false;

  /// Shows the same recording-consent acknowledgement Roast a Stranger shows
  /// before joining - now shown when JOINING a tournament too, not only right
  /// before a battle (developer's call, 2026-09-15). Returns whether the
  /// player consented; caches a yes for the rest of this tournament session so
  /// the first battle after joining does not ask again.
  Future<bool> _ensureConsent() async {
    if (_consented) return true;
    final consented = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RecordingConsentScreen()),
    );
    if (consented == true) {
      _consented = true;
      return true;
    }
    return false;
  }

  DocumentReference<Map<String, dynamic>> get _tournamentRef =>
      FirebaseFirestore.instance.collection('tournaments').doc(widget.tournamentId);

  CollectionReference<Map<String, dynamic>> get _entrantsRef => _tournamentRef.collection('entrants');

  String get _uid => FirebaseAuth.instance.currentUser!.uid;

  /// The "play your match" block, or a plain statement of why there is
  /// nothing to play.
  List<Widget> _playSection(Map<String, dynamic> tournament) {
    final state = tournamentPlayState(tournament, _uid);
    if (!state.canPlay) {
      if (state.note == null) return const [];
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(state.note!,
              style: Theme.of(context).textTheme.bodyMedium),
        ),
      ];
    }
    return [
      const SizedBox(height: 8),
      FilledButton(
        onPressed: _busy ? null : _playMatch,
        child: const Text('Play your match'),
      ),
      const SizedBox(height: 8),
    ];
  }

  /// Recording consent and the camera check first, exactly as an ordinary
  /// match does. A tournament match is still recorded and still eligible
  /// for the highlight pipeline, so the consent step is not optional -
  /// and the camera check is worth more here, not less, since a bracket
  /// match cannot simply be requeued if the setup is bad.
  Future<void> _playMatch() async {
    if (!await _ensureConsent() || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PreMatchScreen(
          mode: 'tournament',
          tournamentId: widget.tournamentId,
        ),
      ),
    );
  }

  Future<void> _join() async {
    if (!await _ensureConsent() || !mounted) return;
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      await _entrantsRef.doc(_uid).set({'joinedAt': FieldValue.serverTimestamp()});
    } catch (e) {
      if (mounted) setState(() => _statusMessage = 'Failed to join: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withdraw() async {
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      await _entrantsRef.doc(_uid).delete();
    } catch (e) {
      if (mounted) setState(() => _statusMessage = 'Failed to withdraw: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _callDebugFunction(String name) async {
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(name);
      final result = await callable.call({'tournamentId': widget.tournamentId});
      if (mounted) setState(() => _statusMessage = result.data.toString());
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => _statusMessage = 'Failed: ${e.message ?? e.code}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What a player is told about how full a tournament is.
  ///
  /// A phrase rather than a number: the point is to convey momentum and
  /// the cancellation risk without publishing a discouraging integer.
  String _entrantStatus(String status, int count, num min) {
    if (status == 'cancelled') {
      return 'Cancelled - not enough entrants. Any fee is refunded.';
    }
    if (status == 'completed') return 'Finished.';
    if (status == 'in_progress') return 'Under way.';
    // Still open. Deliberately only two states, so nobody can infer the
    // exact count by watching the wording change.
    return count >= min
        ? 'Ready to run - enough people are in.'
        : 'Filling up. This only runs if enough people enter, and if it '
            'does not, entry is refunded.';
  }

  String _short(String? uid) {
    if (uid == null) return 'BYE';
    return uid.length > 8 ? uid.substring(0, 8) : uid;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070509),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Tournament', style: TextStyle(color: Colors.white)),
      ),
      body: Stack(
        children: [
          // Light-touch arena wash: the same crown/crowd art as the Home hero
          // and the My Tournaments list, but dim (60%) and only at the very
          // top, fading fast to near-black by ~a third down - the same world
          // as a restrained echo rather than a fourth full-screen background.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Opacity(
              opacity: 0.6,
              child: Image.asset(
                _detailBgAsset,
                fit: BoxFit.fitWidth,
                alignment: Alignment.topCenter,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x40000000),
                    Color(0xCC070509),
                    Color(0xFF070509),
                    Color(0xFF070509),
                  ],
                  stops: [0.0, 0.20, 0.34, 1.0],
                ),
              ),
            ),
          ),
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: _tournamentRef.snapshots(),
            builder: (context, tournamentSnapshot) {
          if (!tournamentSnapshot.hasData || !tournamentSnapshot.data!.exists) {
            return const Center(child: CircularProgressIndicator());
          }
          final tournament = tournamentSnapshot.data!.data()!;
          final name = tournament['name'] as String? ?? 'Unnamed tournament';
          final description = tournament['description'] as String? ?? '';
          final status = tournament['status'] as String? ?? 'open';
          final prizeType = tournament['prizeType'] as String? ?? 'points';
          final minEntrants = tournament['minEntrants'] as num? ?? 4;
          final winnerId = tournament['winnerId'] as String?;
          final bracket = tournament['bracket'] as Map<String, dynamic>?;

          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _entrantsRef.snapshots(),
            builder: (context, entrantsSnapshot) {
              final entrantDocs = entrantsSnapshot.data?.docs ?? [];
              final entrantIds = entrantDocs.map((d) => d.id).toList();
              final isEntrant = entrantIds.contains(_uid);
              final isOpen = status == 'open';
              final isLive = tournament['format'] == 'live';
              // A climb tournament (the nightly Sixes and Sevens format) has
              // no pre-seeded bracket, entrants list, or check-in - joining is
              // the ClimbScreen, and the bracket-specific UI below is skipped.
              final isClimb = tournament['format'] == 'climb';
              // Whether the signed-in player is already in tonight's bracket,
              // read from their own entrant document (one listener, not two).
              Map<String, dynamic>? myEntrant;
              for (final d in entrantDocs) {
                if (d.id == _uid) {
                  myEntrant = d.data();
                  break;
                }
              }
              final checkedIn = hasCheckedIn(myEntrant);

              return ListView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  MediaQuery.of(context).padding.top + kToolbarHeight + 8,
                  24,
                  24 + MediaQuery.of(context).padding.bottom,
                ),
                children: [
                  Text(name, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  if (description.isNotEmpty) ...[
                    Text(description),
                    const SizedBox(height: 8),
                  ],
                  Text('Status: $status'),
                  Text('Prize: $prizeType'),
                  // Climb: one clear entry into the rolling ladder. Everything
                  // bracket-specific below is guarded off for this format.
                  if (isClimb) ...[
                    const SizedBox(height: 16),
                    if (status == 'open' || status == 'in_progress')
                      FilledButton.icon(
                        onPressed: () async {
                          // Recording-consent acknowledgement before joining,
                          // same as Roast a Stranger; ClimbScreen is told it
                          // is already consented so the first battle does not
                          // ask again. Capture the navigator before the await
                          // so no BuildContext is used across the async gap.
                          final navigator = Navigator.of(context);
                          final consented = await _ensureConsent();
                          if (!consented || !mounted) return;
                          await navigator.push(
                            MaterialPageRoute(
                              builder: (_) => ClimbScreen(
                                tournamentId: widget.tournamentId,
                                name: name,
                                consented: true,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.trending_up),
                        label: const Text('Enter the gauntlet'),
                      )
                    else
                      const Text('This gauntlet has finished.'),
                  ],
                  // THE ENTRANT COUNT IS HIDDEN FROM PLAYERS, on purpose.
                  //
                  // "3 entrants" reads as dead and stops the fourth person
                  // entering, which is a real cold-start problem when a
                  // tournament needs a minimum to run at all. With a FIXED
                  // prize nobody needs the number to know what they are
                  // playing for - every raffle and contest works this way.
                  //
                  // It would stop being fair the moment the prize became a
                  // share of the pool, because then entrants genuinely
                  // could not evaluate what they were buying. If prizes
                  // ever go pari-mutuel, this has to come back.
                  //
                  // What must NOT be hidden is that a tournament can be
                  // cancelled below its minimum - that is the entrant's
                  // real risk, so it is stated in words instead.
                  // Entrant count / cancellation risk is a bracket concept -
                  // a climb has no fixed entrant list (it uses climb.climbers).
                  if (!isClimb) ...[
                    Text(_entrantStatus(status, entrantIds.length, minEntrants)),
                    // The developer sees the real number, since running an
                    // event means knowing whether it will actually fill.
                    AdminOnly(
                      child: Text(
                        'Admin: ${entrantIds.length} entrants (min $minEntrants)',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  // Live events only - the single one-tap "Join tonight's
                  // tournament" control. Renders nothing for the async
                  // format, which has no join window at all.
                  LiveCheckIn(
                    tournamentId: widget.tournamentId,
                    tournament: tournament,
                    checkedIn: checkedIn,
                    // Recording-consent acknowledgement before checking in,
                    // matching Roast a Stranger.
                    onConsent: _ensureConsent,
                  ),
                  if (winnerId != null) Text('Winner: ${_short(winnerId)}'),
                  const SizedBox(height: 24),
                  // The async Join/Withdraw is hidden for LIVE tournaments -
                  // there, joining is the one-tap LiveCheckIn above, and a
                  // second "Join" button would be exactly the two-step
                  // confusion this redesign removed.
                  if (isOpen && !isLive && !isClimb)
                    FilledButton(
                      onPressed: _busy ? null : (isEntrant ? _withdraw : _join),
                      child: Text(isEntrant ? 'Withdraw' : 'Join'),
                    ),
                  const SizedBox(height: 12),
                  // Both bracket controls are admin tooling, hidden from
                  // entrants: the server gates them on the same isAdmin
                  // flag, and an entrant tapping "Advance Round" would be
                  // told "Admin only" - which reads as a broken app rather
                  // than as a control that was never theirs.
                  if (isOpen && !isClimb)
                    AdminOnly(
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => _callDebugFunction('generateTournamentBracket'),
                        child: const Text('Generate Bracket (test)'),
                      ),
                    ),
                  // The way into an actual bracket match. Shown only when
                  // this player genuinely has one to play, so the button
                  // never appears for someone with a bye, someone already
                  // knocked out, or a round whose window has closed - the
                  // server refuses all three anyway, and offering an
                  // action that is certain to fail reads as a bug.
                  // The way IN to watching. Without it a live event is
                  // perfect and unwatchable, because the only route to a
                  // battle was already knowing its match id - the same
                  // class of gap as a report button reachable only after
                  // finishing a match.
                  WatchLiveList(
                    tournamentId: widget.tournamentId,
                    isLiveAndRunning: tournament['format'] == 'live' &&
                        status == 'in_progress',
                  ),
                  if (status == 'in_progress') ..._playSection(tournament),
                  if (status == 'in_progress')
                    AdminOnly(
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => _callDebugFunction('debugAdvanceTournamentRound'),
                        child: const Text('Advance Round (test)'),
                      ),
                    ),
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 16),
                    Text(_statusMessage!),
                  ],
                  if (bracket != null) ...[
                    const SizedBox(height: 24),
                    Text('Bracket', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    ..._buildRounds(bracket),
                  ],
                ],
              );
            },
          );
            },
          ),
        ],
      ),
    );
  }

  List<Widget> _buildRounds(Map<String, dynamic> bracket) {
    final rounds = (bracket['rounds'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    return rounds.map((round) {
      final roundNumber = round['roundNumber'];
      final matchups = (round['matchups'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Round $roundNumber', style: Theme.of(context).textTheme.titleSmall),
            ...matchups.map((m) {
              final p1 = _short(m['player1Id'] as String?);
              final p2 = _short(m['player2Id'] as String?);
              final winnerId = m['winnerId'] as String?;
              final isBye = m['isBye'] as bool? ?? false;
              final label = isBye ? '$p1 vs $p2 (bye)' : '$p1 vs $p2';
              final winnerLabel = winnerId != null ? ' → ${_short(winnerId)}' : '';
              return Text('$label$winnerLabel');
            }),
          ],
        ),
      );
    }).toList();
  }
}
