import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services/matchmaking_service.dart';
import 'match_screen.dart';

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
        MaterialPageRoute(builder: (_) => MatchScreen(pairing: pairing)),
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
