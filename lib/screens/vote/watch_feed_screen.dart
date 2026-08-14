import 'package:flutter/material.dart';

import '../../core/services/watch_feed_service.dart';
import '../../widgets/turnstile_challenge.dart';
import 'feed_page.dart';

/// The Judge tab: one vertical feed of battles.
///
/// Battles still needing judgement come first, ordered by urgency; the
/// archive follows by popularity. There is no separate "watch" tab and no
/// separate "judge" queue, because they would show the same clips the same
/// way - and a judging queue EMPTIES, leaving a dead tab until more matches
/// finish. Merged, the feed simply flows from work into entertainment.
///
/// Voting is verified ONCE per session rather than per ballot. A CAPTCHA
/// between every video would make judging a chore, and votes are what the
/// whole ranking system runs on.
class WatchFeedScreen extends StatefulWidget {
  const WatchFeedScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<WatchFeedScreen> createState() => _WatchFeedScreenState();
}

class _WatchFeedScreenState extends State<WatchFeedScreen> {
  final _service = WatchFeedService();
  final _pageController = PageController();

  List<FeedMatch>? _matches;
  String? _error;
  int _index = 0;
  int _votesRemaining = 0;
  bool _challenging = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _matches = null;
      _error = null;
    });
    try {
      final page = await _service.fetch();
      final remaining = await _service.sessionVotesRemaining();
      if (!mounted) return;
      setState(() {
        _matches = page.matches;
        _votesRemaining = remaining;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not load battles: $e');
    }
  }

  /// Casts a ballot, opening a session first if there isn't a usable one.
  ///
  /// The challenge is raised BEFORE the vote rather than after a rejection,
  /// so the interruption lands once at the start of a judging run instead
  /// of arriving as an error mid-scroll.
  Future<bool> _vote(String matchId, String votedForPlayerId) async {
    try {
      if (_votesRemaining <= 0) {
        final token = await _requestChallenge();
        if (token == null) return false;
        await _service.startSession(token);
        if (!mounted) return false;
        setState(() => _votesRemaining = 25);
      }
      await _service.castVote(
          matchId: matchId, votedForPlayerId: votedForPlayerId);
      if (mounted) setState(() => _votesRemaining -= 1);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Vote failed: $e')),
        );
      }
      return false;
    }
  }

  /// Shows the CAPTCHA in a sheet and resolves with its token.
  Future<String?> _requestChallenge() async {
    if (_challenging) return null;
    setState(() => _challenging = true);
    final token = await showModalBottomSheet<String>(
      context: context,
      isDismissible: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Quick check before you start judging',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('Once only - then judge as many battles as you like.',
                style: TextStyle(fontSize: 12), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            TurnstileChallenge(
              onToken: (t) => Navigator.of(sheetContext).pop(t),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() => _challenging = false);
    return token;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: false,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    if (_matches == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_matches!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No battles to watch yet.\nOnce ranked matches finish, they show '
            'up here to be judged.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    return PageView.builder(
      controller: _pageController,
      scrollDirection: Axis.vertical,
      itemCount: _matches!.length,
      onPageChanged: (i) => setState(() => _index = i),
      itemBuilder: (context, i) {
        final match = _matches![i];
        return FeedPage(
          key: ValueKey(match.matchId),
          match: match,
          isActive: i == _index,
          onVote: (playerId) => _vote(match.matchId, playerId),
        );
      },
    );
  }
}
