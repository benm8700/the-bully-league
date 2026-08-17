import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../widgets/admin_only.dart';
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
  bool _busy = false;
  String? _statusMessage;

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
    final consented = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RecordingConsentScreen()),
    );
    if (consented != true || !mounted) return;
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

  String _short(String? uid) {
    if (uid == null) return 'BYE';
    return uid.length > 8 ? uid.substring(0, 8) : uid;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tournament')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
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
              final entrantIds = entrantsSnapshot.data?.docs.map((d) => d.id).toList() ?? [];
              final isEntrant = entrantIds.contains(_uid);
              final isOpen = status == 'open';

              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(name, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  if (description.isNotEmpty) ...[
                    Text(description),
                    const SizedBox(height: 8),
                  ],
                  Text('Status: $status'),
                  Text('Prize: $prizeType'),
                  Text('Entrants: ${entrantIds.length} (min $minEntrants)'),
                  if (winnerId != null) Text('Winner: ${_short(winnerId)}'),
                  const SizedBox(height: 24),
                  if (isOpen)
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
                  if (isOpen)
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
