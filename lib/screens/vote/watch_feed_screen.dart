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

  int? _cursorMs;
  bool _exhausted = false;
  bool _loadingMore = false;

  /// How far from the end to start fetching. Loading a page ahead means the
  /// next clip is already initialising while the current one plays, rather
  /// than the feed stalling on a spinner at the moment someone swipes.
  static const _prefetchWithin = 3;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Anything left over goes now, or leaving the tab loses it.
    _flushCalls();
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
        _cursorMs = page.nextCursorMs;
        _exhausted = page.nextCursorMs == null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not load battles: $e');
    }
  }

  /// Fetches the next page and appends it.
  ///
  /// Keeps walking while the server returns a cursor but no usable matches,
  /// which happens when a whole window of the archive has no rendered
  /// clips. Without that the feed would look exhausted while plenty of
  /// watchable battles sat just past the gap. Bounded so a long barren
  /// stretch cannot spin forever.
  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted || _cursorMs == null) return;
    _loadingMore = true;
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        final page = await _service.fetch(cursorMs: _cursorMs);
        if (!mounted) return;
        final existing = {for (final m in _matches ?? const []) m.matchId};
        final fresh =
            page.matches.where((m) => !existing.contains(m.matchId)).toList();
        setState(() {
          _matches = [...?_matches, ...fresh];
          _cursorMs = page.nextCursorMs;
          _exhausted = page.nextCursorMs == null;
        });
        if (fresh.isNotEmpty || _exhausted) break;
      }
    } catch (_) {
      // A failed page must not break the clips already on screen; the next
      // swipe simply tries again.
    } finally {
      _loadingMore = false;
    }
  }

  /// Calls made on settled battles, waiting to be sent.
  ///
  /// Batched rather than sent per clip: a call happens on every archive
  /// video someone scrolls past, and one function invocation behind every
  /// swipe would be a lot of calls for a passive stat.
  final List<Map<String, String>> _pendingCalls = [];
  static const _flushCallsAt = 5;

  void _recordCall(String matchId, String chosenPlayerId) {
    _pendingCalls.add({'matchId': matchId, 'chosenPlayerId': chosenPlayerId});
    if (_pendingCalls.length >= _flushCallsAt) _flushCalls();
  }

  /// Sends whatever has accumulated.
  ///
  /// Failures are swallowed and the batch dropped rather than retried: a
  /// lost judge stat is not worth an error in front of someone watching a
  /// video, and retrying risks double-counting - which the server guards
  /// against anyway, but there is no reason to lean on that.
  void _flushCalls() {
    if (_pendingCalls.isEmpty) return;
    final batch = List<Map<String, String>>.from(_pendingCalls);
    _pendingCalls.clear();
    _service.recordCalls(batch).catchError((_) {});
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
      final reward = await _service.castVote(
        matchId: matchId,
        votedForPlayerId: votedForPlayerId,
      );
      if (mounted) {
        setState(() => _votesRemaining -= 1);
        // Show the reward landing. The window bonus has been paid since it
        // was built and nothing ever mentioned it - a bonus nobody
        // notices motivates nobody.
        // An earned SKIP leads over everything, including the streak.
        // It is the rarest of these, it is the one that is genuinely
        // useful to a competitive player who will never spend a point,
        // and it is announced on exactly the vote that crossed the
        // threshold - a line repeated on every vote afterwards is one
        // people stop reading.
        //
        // Shown even when the vote paid no points, since the daily
        // points cap and the skip threshold are separate ceilings and a
        // capped voter can still be earning skips.
        if (reward.skipJustEarned) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              duration: Duration(seconds: 4),
              content: Text('Skip earned - judging just bought you an '
                  'extra skip today.'),
            ),
          );
        } else if (reward.points > 0) {
          // The streak leads when it just paid, because a run is the more
          // motivating number and it only lands once a day - the per-vote
          // points show up on every single vote and say nothing new.
          final message = reward.extendedStreak
              ? '${reward.streakDays} day streak - '
                  '+${reward.points + reward.streakPoints} points'
              : reward.boosted
                  ? '+${reward.points} points - ${_x(reward.multiplier)}x bonus'
                  : '+${reward.points} points';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: Duration(seconds: reward.extendedStreak ? 3 : 2),
              content: Text(message),
            ),
          );
        }
      }
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

  /// Renders a whole multiplier as "2" rather than "2.0".
  String _x(double m) =>
      m == m.roundToDouble() ? m.toStringAsFixed(0) : m.toString();

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
      onPageChanged: (i) {
        setState(() => _index = i);
        if (i >= _matches!.length - _prefetchWithin) _loadMore();
      },
      itemBuilder: (context, i) {
        final match = _matches![i];
        return FeedPage(
          key: ValueKey(match.matchId),
          match: match,
          isActive: i == _index,
          onVote: (playerId) => _vote(match.matchId, playerId),
          onCall: _recordCall,
        );
      },
    );
  }
}
