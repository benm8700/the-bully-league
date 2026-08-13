import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/services/matchmaking_service.dart';
import 'match_screen.dart';

/// Pre-match bio reveal (CLAUDE.md's "Pre-match bio reveal" decision).
///
/// Shown once matchmaking has paired two players, before the video call
/// starts. The point is ammo: without it a roaster is improvising about a
/// total stranger with nothing but their appearance to work with, which is
/// both harder and pushes the material somewhere the profile system was
/// deliberately designed to steer away from.
///
/// Ends after [_revealSeconds] OR as soon as both players tap Ready,
/// whichever comes first. Either player may decline the pairing here
/// instead, spending one of their limited daily skips.
///
/// Deliberately NOT shown during the match itself - CLAUDE.md keeps the
/// full bio pre-match only, to keep the video UI clean and to test what
/// the roaster actually remembered.
///
/// The reveal length is hardcoded here rather than read from Firebase
/// Remote Config, the same outstanding gap MatchScreen has for round
/// count/length (CLAUDE.md's config/matchSettings schema lists
/// bioRevealSeconds alongside them).
class BioRevealScreen extends StatefulWidget {
  const BioRevealScreen({super.key, required this.pairing});

  final MatchPairing pairing;

  @override
  State<BioRevealScreen> createState() => _BioRevealScreenState();
}

class _BioRevealScreenState extends State<BioRevealScreen> {
  static const _revealSeconds = 60;

  final _service = MatchmakingService();

  Map<String, dynamic>? _opponent;
  String? _loadError;
  int _secondsLeft = _revealSeconds;
  int? _skipsLeft;
  bool _iAmReady = false;
  bool _bothReady = false;
  bool _busy = false;
  bool _navigated = false;
  String? _endedReason;

  Timer? _ticker;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _matchSub;

  @override
  void initState() {
    super.initState();
    _loadOpponent();
    _loadSkips();
    _watchMatch();
    _startTicker();
  }

  Future<void> _loadOpponent() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.pairing.opponentId)
          .get();
      if (!mounted) return;
      setState(() => _opponent = snap.data());
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = "Couldn't load your opponent's profile.");
    }
  }

  Future<void> _loadSkips() async {
    try {
      final remaining = await _service.skipsRemaining();
      if (mounted) setState(() => _skipsLeft = remaining);
    } catch (_) {
      // Non-fatal: the button just won't show a count. Skipping itself is
      // still enforced server-side.
    }
  }

  /// Both sides watch the match document: it's how each learns the other
  /// tapped Ready, and how the player who DIDN'T skip finds out that the
  /// pairing was declined.
  void _watchMatch() {
    _matchSub = FirebaseFirestore.instance
        .collection('matches')
        .doc(widget.pairing.matchId)
        .snapshots()
        .listen((snap) {
      final data = snap.data();
      if (data == null || !mounted) return;

      if (data['status'] != 'pending') {
        final skippedBy = data['skippedByUserId'] as String?;
        _endMatch(
          skippedBy == widget.pairing.opponentId
              ? 'Your opponent passed on this one. Finding you someone else...'
              : 'This match ended before it started.',
        );
        return;
      }

      final ready = (data['readyPlayerIds'] as List?)?.cast<String>() ?? const [];
      if (ready.length >= 2 && !_bothReady) {
        setState(() => _bothReady = true);
        _goToMatch();
      }
    });
  }

  void _startTicker() {
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_secondsLeft <= 1) {
        timer.cancel();
        setState(() => _secondsLeft = 0);
        // Time's up - the match starts whether or not both tapped Ready,
        // per "up to 1 minute OR until both players tap ready".
        _goToMatch();
        return;
      }
      setState(() => _secondsLeft -= 1);
    });
  }

  Future<void> _onReady() async {
    if (_busy || _iAmReady) return;
    setState(() {
      _busy = true;
      _iAmReady = true;
    });
    try {
      await _service.setReady(widget.pairing.matchId);
    } catch (e) {
      // Not fatal: the timer still starts the match, and the opponent's
      // own timer will too. Undo the local flag so they can retry.
      if (mounted) setState(() => _iAmReady = false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onSkip() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final remaining = await _service.skipMatch(widget.pairing.matchId);
      if (!mounted) return;
      setState(() => _skipsLeft = remaining);
      _endMatch('Match skipped. $remaining ${remaining == 1 ? 'skip' : 'skips'} left today.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final exhausted = e.toString().contains('skips');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(exhausted
            ? "You've used all of today's skips."
            : "Couldn't skip this match: $e"),
      ));
    }
  }

  void _goToMatch() {
    if (_navigated || _endedReason != null) return;
    _navigated = true;
    _ticker?.cancel();
    _matchSub?.cancel();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => MatchScreen(pairing: widget.pairing)),
    );
  }

  void _endMatch(String reason) {
    if (_navigated || _endedReason != null) return;
    _ticker?.cancel();
    setState(() => _endedReason = reason);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _matchSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Opponent'),
        automaticallyImplyLeading: false,
      ),
      body: _endedReason != null ? _buildEndedUi() : _buildRevealUi(),
    );
  }

  Widget _buildEndedUi() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_off_outlined, size: 48),
            const SizedBox(height: 16),
            Text(_endedReason!, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRevealUi() {
    final profile = (_opponent?['profile'] as Map?)?.cast<String, dynamic>();
    final username = _opponent?['username'] as String? ?? 'Your opponent';

    return Column(
      children: [
        _buildTimerBar(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  username,
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  'Here\'s your ammo. Use it.',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                if (_loadError != null)
                  Text(_loadError!, textAlign: TextAlign.center)
                else if (_opponent == null)
                  const Center(child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ))
                else
                  ..._buildProfileFields(profile),
              ],
            ),
          ),
        ),
        _buildActions(),
      ],
    );
  }

  List<Widget> _buildProfileFields(Map<String, dynamic>? profile) {
    // Rank/rating is deliberately absent - CLAUDE.md keeps it out of the
    // bio reveal so the focus stays on comedy material rather than
    // skill intimidation or sandbagging psychology.
    const fields = <String, String>{
      'profession': 'Profession',
      'education': 'Education',
      'hometown': 'Hometown',
      'interests': 'Interests',
      'relationshipStatus': 'Relationship status',
      'pets': 'Pets',
      'favoriteFood': 'Favorite food',
    };

    final rows = <Widget>[];
    for (final entry in fields.entries) {
      final value = profile?[entry.key] as String?;
      if (value == null || value.trim().isEmpty) continue;
      rows.add(_BioRow(label: entry.value, value: value));
    }

    final ammo = profile?['ammoText'] as String?;
    if (ammo != null && ammo.trim().isNotEmpty) {
      rows.add(const SizedBox(height: 12));
      rows.add(Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.local_fire_department_outlined, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    'They volunteered this',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(ammo),
            ],
          ),
        ),
      ));
    }

    if (rows.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Text(
            'This one left their profile blank. You\'re on your own.',
            textAlign: TextAlign.center,
          ),
        ),
      ];
    }
    return rows;
  }

  Widget _buildTimerBar() {
    final fraction = (_secondsLeft / _revealSeconds).clamp(0.0, 1.0);
    return Column(
      children: [
        LinearProgressIndicator(value: fraction, minHeight: 4),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _iAmReady && !_bothReady
                ? 'Waiting for your opponent... ${_secondsLeft}s'
                : 'Match starts in ${_secondsLeft}s',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    final skipsLeft = _skipsLeft;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            onPressed: (_busy || _iAmReady) ? null : _onReady,
            child: Text(_iAmReady ? 'Ready - waiting for opponent' : "I'm Ready"),
          ),
          const SizedBox(height: 8),
          if (skipsLeft == null || skipsLeft > 0)
            TextButton(
              onPressed: _busy ? null : _onSkip,
              child: Text(
                skipsLeft == null
                    ? 'Skip this opponent'
                    : 'Skip this opponent ($skipsLeft left today)',
              ),
            )
          else
            Text(
              'No skips left today.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _BioRow extends StatelessWidget {
  const _BioRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 2),
          Text(value, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}
