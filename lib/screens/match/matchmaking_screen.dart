import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/services/event_window.dart';
import '../../core/services/matchmaking_service.dart';
import '../../core/services/presence.dart';
import 'bio_reveal_screen.dart';

/// The "finding you an opponent" step (Build Order step 4's missing half).
///
/// Before this existed, both devices joined a hardcoded "test-channel" -
/// there was no way to be paired with a stranger at all. The actual
/// pairing decision is entirely server-side (functions/matchmaking.js);
/// this screen just drives MatchmakingService and reports progress.
class MatchmakingScreen extends StatefulWidget {
  const MatchmakingScreen({super.key, required this.mode});

  /// 'exhibition' or 'ranked'. Each mode has its own queue, so an
  /// exhibition player is never paired into a rated match.
  final String mode;

  @override
  State<MatchmakingScreen> createState() => _MatchmakingScreenState();
}

class _MatchmakingScreenState extends State<MatchmakingScreen> {
  static const _quietHintAfterSeconds = 25;

  final _cancel = Completer<void>();
  final _service = MatchmakingService();

  MatchmakingProgress? _progress;
  String? _error;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    try {
      final pairing = await _service.findMatch(
        mode: widget.mode,
        cancel: _cancel.future,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted || pairing == null) return;
      // pushReplacement so Back from the match returns Home rather than
      // dropping the player into a search for another opponent.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => BioRevealScreen(pairing: pairing)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(e));
    }
  }

  String _friendlyError(Object e) {
    final message = e.toString();
    if (message.contains("account can't join matches")) {
      return 'This account can\'t join matches right now.';
    }
    return 'Couldn\'t find a match: $message';
  }

  void _onCancel() {
    if (_leaving) return;
    setState(() => _leaving = true);
    if (!_cancel.isCompleted) _cancel.complete();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    // findMatch's own finally block leaves the queue when this completes -
    // important on a back-gesture exit, which doesn't go through _onCancel.
    if (!_cancel.isCompleted) _cancel.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.mode == 'ranked' ? 'Ranked Match' : 'Exhibition Match'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _error != null ? _buildErrorUi() : _buildSearchingUi(),
        ),
      ),
    );
  }

  Widget _buildErrorUi() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 48),
        const SizedBox(height: 16),
        Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back to Home'),
        ),
      ],
    );
  }

  Widget _buildSearchingUi() {
    final waited = _progress?.waited ?? Duration.zero;
    final band = _progress?.tierBand ?? 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        const CircularProgressIndicator(),
        const SizedBox(height: 32),
        Text(
          'Finding you an opponent...',
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          _waitLabel(waited),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        // The server widens the acceptable tier gap the longer someone
        // waits (CLAUDE.md's matchmaking fallback decision), so say so
        // rather than leaving a silent spinner during a quiet period.
        Text(
          _searchRangeLabel(band),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        // The highest-conversion place in the whole app to mention the
        // daily window: someone staring at a spinner during a quiet hour
        // has just discovered the problem the window exists to solve, and
        // is more receptive to "come back at 6" than they will ever be
        // again. Turns a matchmaking failure into a scheduling nudge.
        //
        // Held back for the first stretch of the wait - a pairing that
        // arrives in ten seconds shouldn't be preceded by an apology.
        if (waited.inSeconds >= _quietHintAfterSeconds) ...[
          const SizedBox(height: 24),
          const _QuietQueueHint(),
        ],
        const SizedBox(height: 40),
        OutlinedButton(
          onPressed: _leaving ? null : _onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  /// The server's tier band keeps counting up with wait time and has no
  /// ceiling, so past the width of the ladder it stops meaning anything -
  /// seen live reading "widening the search (17 tiers either way)" when
  /// there are only ten ranks. Cap the reported range at the ladder and
  /// say plainly that it's now searching everyone.
  static const _ladderSize = 10;

  String _searchRangeLabel(int band) {
    if (band == 0) return 'Looking for someone in your tier.';
    if (band >= _ladderSize) {
      return 'Still looking - searching across every tier now.';
    }
    final tiers = band == 1 ? '1 tier' : '$band tiers';
    return 'Nobody in your tier right now - widening the search '
        '($tiers either way).';
  }

  String _waitLabel(Duration waited) {
    final seconds = waited.inSeconds;
    if (seconds < 60) return 'Searching for ${seconds}s';
    final minutes = waited.inMinutes;
    return 'Searching for ${minutes}m ${seconds % 60}s';
  }
}

/// Shown once a wait has gone on long enough to feel quiet: tells the
/// player when the app is actually busy, and how many people are here now.
///
/// Two states, both honest. If people ARE online it says so, because a real
/// number reframes the wait as bad luck rather than as an empty app. If
/// nobody is, it points at the window instead - which is the true and
/// useful answer, and far better than leaving someone to conclude on their
/// own that nothing here works.
class _QuietQueueHint extends StatelessWidget {
  const _QuietQueueHint();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('config')
          .doc('eventWindow')
          .snapshots(),
      builder: (context, configSnap) {
        if (configSnap.hasError) return const SizedBox.shrink();
        final config = EventWindowConfig.fromMap(configSnap.data?.data());
        if (!config.enabled) return const SizedBox.shrink();

        final now = DateTime.now().toUtc();
        final window = currentOrNextWindow(now, config);
        // During the window there is nothing useful to promise - they are
        // already at the busiest moment of the day.
        if (window.contains(now)) return const SizedBox.shrink();

        return StreamBuilder<OnlineCount?>(
          stream: onlineCountStream(),
          builder: (context, countSnap) {
            final count = countSnap.data;
            final others = (count != null && count.isFresh)
                // Discount the caller, who is in the queue being counted.
                ? (count.total - 1).clamp(0, 1 << 30)
                : null;

            return Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    Text(
                      others != null && others > 0
                          ? 'A few people are around - hang tight'
                          : 'It\'s quiet right now',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${config.name} is the busiest hour of the day - '
                      '6pm-7pm Pacific. That\'s when everyone is here.',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
