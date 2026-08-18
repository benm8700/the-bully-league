import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/services/matchmaking_service.dart';
import 'match_screen.dart';
import 'matchmaking_screen.dart';

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
/// The reveal length comes from live configuration (CLAUDE.md's
/// config/matchSettings `bioRevealSeconds`), resolved server-side at
/// pairing time and carried on the pairing, so both players count down
/// together and the value can be retuned without a new app release.
class BioRevealScreen extends StatefulWidget {
  const BioRevealScreen({super.key, required this.pairing});

  final MatchPairing pairing;

  @override
  State<BioRevealScreen> createState() => _BioRevealScreenState();
}

class _BioRevealScreenState extends State<BioRevealScreen> {
  int get _revealSeconds => widget.pairing.settings.bioRevealSeconds;

  final _service = MatchmakingService();

  Map<String, dynamic>? _opponent;
  String? _loadError;
  late int _secondsLeft = _revealSeconds;
  int? _skipsLeft;

  /// How many of today's allowance judging paid for. Shown only when
  /// non-zero, since for most players there is nothing to explain.
  int _skipsEarned = 0;
  bool _iAmReady = false;
  bool _bothReady = false;
  bool _busy = false;
  bool _navigated = false;
  String? _endedReason;

  Timer? _ticker;
  Timer? _heartbeat;
  bool _opponentGone = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _matchSub;

  /// How long without a sign of the opponent before offering a way out.
  /// Must stay comfortably under the server's threshold so the button
  /// never appears before the server would honour it.
  static const _opponentStaleAfter = Duration(seconds: 75);

  @override
  void initState() {
    super.initState();
    _loadOpponent();
    _loadSkips();
    _watchMatch();
    _startTicker();
    _startHeartbeat();
  }

  /// Says "still here" without saying "ready".
  ///
  /// The reveal ends the moment both players tap Ready, so its maximum
  /// only ever matters when one of them doesn't - which means a long
  /// window's real cost is being held by somebody who walked away. Ready
  /// alone can't tell that apart from someone thinking hard about their
  /// material, and throwing the latter out would collapse a ten-minute
  /// window back to seconds.
  void _startHeartbeat() {
    _service.sendPresence(widget.pairing.matchId);
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _service.sendPresence(widget.pairing.matchId);
    });
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
      final allowance = await _service.skipsRemaining();
      if (mounted) {
        setState(() {
          _skipsLeft = allowance.remaining;
          _skipsEarned = allowance.earned;
        });
      }
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
        if (skippedBy == widget.pairing.opponentId) {
          // Put them straight back in the queue rather than dumping them
          // on Home. Being declined is already a small rejection; making
          // the player re-navigate the whole consent and camera-check flow
          // to try again compounds it for no reason, and they passed those
          // checks moments ago.
          _requeue();
        } else {
          _endMatch('This match ended before it started.');
        }
        return;
      }

      final ready = (data['readyPlayerIds'] as List?)?.cast<String>() ?? const [];
      if (ready.length >= 2 && !_bothReady) {
        setState(() => _bothReady = true);
        _goToMatch();
        return;
      }

      // Surface a way out once the opponent has stopped signalling. The
      // server decides whether a release is actually allowed; this only
      // decides when to offer it, and errs on the late side so the button
      // never appears before the server would honour it.
      final seen = data['lastSeenAt'] as Map<String, dynamic>?;
      final theirLastSeen = (seen?[widget.pairing.opponentId] as num?)?.toInt();
      final opponentReady = ready.contains(widget.pairing.opponentId);
      final referenceMs = theirLastSeen ??
          (data['createdAt'] as Timestamp?)?.millisecondsSinceEpoch;
      final gone = !opponentReady &&
          referenceMs != null &&
          DateTime.now().millisecondsSinceEpoch - referenceMs >
              _opponentStaleAfter.inMilliseconds;
      if (gone != _opponentGone) setState(() => _opponentGone = gone);
    });
  }

  Future<void> _leaveUnresponsive() async {
    if (_busy) return;
    setState(() => _busy = true);
    final released = await _service.releaseUnresponsive(widget.pairing.matchId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (released) {
      // Straight back to searching rather than out to Home: they did
      // nothing wrong and passed consent and the camera check moments ago.
      _requeue();
    } else {
      setState(() => _opponentGone = false);
    }
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

  /// Sends the player back into matchmaking for the same mode after their
  /// opponent declined, replacing this screen so Back still returns Home
  /// rather than to a dead pairing.
  void _requeue() {
    if (_navigated || _endedReason != null) return;
    _navigated = true;
    _ticker?.cancel();
    _matchSub?.cancel();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Your opponent passed. Finding someone else...')),
    );
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => MatchmakingScreen(mode: widget.pairing.mode)),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _heartbeat?.cancel();
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
    // Guarded because bioRevealSeconds is live-configurable and 0 is a
    // legitimate value (skip the reveal entirely) - dividing by it would
    // hand LinearProgressIndicator a NaN.
    final fraction =
        _revealSeconds > 0 ? (_secondsLeft / _revealSeconds).clamp(0.0, 1.0) : 0.0;
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
          // Only ever offered once the opponent has genuinely gone quiet,
          // and it costs no skip - they declined nobody, they were stood up.
          if (_opponentGone) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _leaveUnresponsive,
              icon: const Icon(Icons.person_off_outlined),
              label: const Text('Opponent left - find someone else'),
            ),
          ],
          const SizedBox(height: 8),
          // A friend battle cannot be skipped, and offering it would be
          // nonsense: you chose this person by name and they said yes.
          // The skip allowance exists to escape a stranger the matchmaker
          // picked, and there is no queue here to be returned to.
          if (widget.pairing.mode == 'friend')
            Text(
              'You challenged them. Leaving now just cancels the battle.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            )
          else if (skipsLeft == null || skipsLeft > 0)
            TextButton(
              onPressed: _busy ? null : _onSkip,
              child: Text(
                skipsLeft == null
                    ? 'Skip this opponent'
                    // Judging is named only when it actually paid for
                    // something. For most players the count is just the
                    // base allowance, and an unexplained mention of
                    // judging would be noise.
                    : _skipsEarned > 0
                        ? 'Skip this opponent ($skipsLeft left today, '
                            '$_skipsEarned from judging)'
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
