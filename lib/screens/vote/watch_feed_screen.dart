import 'package:flutter/material.dart';

import '../../core/friendly_error.dart';
import '../../widgets/empty_state.dart';

import '../../core/services/clip_cache.dart';
import '../../core/services/watch_feed_service.dart';
import '../../widgets/turnstile_challenge.dart';
import '../tournament/gauntlet_watch.dart';
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
  const WatchFeedScreen({super.key, this.embedded = false, this.isActiveTab = true});

  final bool embedded;

  /// Whether this is the tab currently on screen. False while the viewer is
  /// on another bottom-nav tab - the shell keeps every tab MOUNTED in an
  /// IndexedStack, so without this the feed clip would keep playing its audio
  /// off-screen (a real device looped a battle's audio after switching away,
  /// 2026-09-16). Defaults true for standalone/pushed use.
  final bool isActiveTab;

  @override
  State<WatchFeedScreen> createState() => _WatchFeedScreenState();
}

class _WatchFeedScreenState extends State<WatchFeedScreen>
    with WidgetsBindingObserver {
  /// The feed clip only plays when the app is foreground. The feed has audio,
  /// so a backgrounded/locked phone must not keep it running.
  bool _appForeground = true;
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
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didUpdateWidget(WatchFeedScreen old) {
    super.didUpdateWidget(old);
    // Returning to the Judge tab reloads it, so a battle that finished
    // rendering while the viewer was on another tab shows up without an app
    // relaunch. The tab is kept mounted in the shell's IndexedStack, so
    // initState fires only once - this is the only signal that the tab has
    // come back into view. Quiet, so clips already on screen do not flash a
    // spinner.
    if (widget.isActiveTab && !old.isActiveTab) {
      _load(quiet: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground != _appForeground) {
      // Rebuild so the active FeedPage recomputes isActive and pauses/plays.
      setState(() => _appForeground = foreground);
    }
    // Coming back from the background also reloads, so clips that rendered
    // while the app was away are picked up. Only when this tab is on screen -
    // no point fetching for a hidden one.
    if (foreground && widget.isActiveTab) {
      _load(quiet: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Anything left over goes now, or leaving the tab loses it.
    _flushCalls();
    _pageController.dispose();
    super.dispose();
  }

  /// Loads (or reloads) the feed.
  ///
  /// [quiet] keeps whatever is already on screen while the new page is
  /// fetched, so a background refresh (returning to the tab, or resuming the
  /// app) never flashes a spinner over clips already in view. A quiet reload
  /// also resets to the top - which is both the point of the Judge tab
  /// ("most urgent first") and how a freshly-rendered clip that finished
  /// AFTER the tab first loaded finally surfaces.
  Future<void> _load({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _matches = null;
        _error = null;
      });
    }
    try {
      final page = await _service.fetch();
      final remaining = await _service.sessionVotesRemaining();
      if (!mounted) return;
      setState(() {
        _matches = page.matches;
        _votesRemaining = remaining;
        _cursorMs = page.nextCursorMs;
        _exhausted = page.nextCursorMs == null;
        _index = 0;
        _error = null;
      });
      if (quiet && _pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
      _prefetchAhead(0);
    } catch (e) {
      if (!mounted) return;
      // A background refresh that fails must not wipe the clips already on
      // screen - only a foreground load surfaces the error. Was
      // 'Could not load battles: $e', which rendered a six-frame Dart stack
      // trace into the middle of the app's main content surface.
      if (!quiet) {
        setState(() => _error = friendlyError(e, doing: 'loading battles'));
      }
    }
  }

  /// Warms the clip cache for the next couple of clips so they are already
  /// local - and therefore instant to rewind and scrub - by the time the
  /// viewer swipes to them.
  void _prefetchAhead(int index) {
    final matches = _matches;
    if (matches == null) return;
    for (var j = index + 1; j <= index + 2 && j < matches.length; j++) {
      final url = matches[j].videoUrl;
      if (url != null && url.isNotEmpty) {
        ClipCacheService.instance.prefetch(url);
      }
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
  Future<bool> _vote(String matchId, Map<int, String> picks,
      Map<String, String> emojiRatings) async {
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
        picks: picks,
        emojiRatings: emojiRatings,
      );
      if (mounted) {
        setState(() {
          _votesRemaining -= 1;
          // Mark this match judged in the source list so a feed page that
          // rebuilds (scrolled away and back) sees canVote:false and shows
          // the tally rather than re-offering the green pick controls on a
          // match the server will now reject as already voted.
          final list = _matches;
          if (list != null) {
            final i = list.indexWhere((m) => m.matchId == matchId);
            if (i != -1) list[i] = list[i].markVoted();
          }
        });
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
          SnackBar(content: Text(friendlyError(e, doing: 'casting your vote'))),
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
    // Cinematic "make the call" comedy-club background (developer's art,
    // 2026-09-14). It sits BEHIND the feed: a playing clip fills the screen
    // opaquely, so the art only shows in the loading / empty / error states -
    // exactly where a bare black screen looked most unfinished. A light scrim
    // keeps the empty-state / error copy legible over the busy stage art.
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/home/vote_background.png',
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
            ),
          ),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x4D000000), Color(0x1A000000), Color(0x66000000)],
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: _buildBody(),
          ),
          // Tournament judging, surfaced where everyone already is. Sits at the
          // top-centre between the vote badge (left) and the clip controls
          // (right); renders nothing unless a gauntlet battle is live.
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 0,
            right: 0,
            child: const Center(child: GauntletLivePill()),
          ),
        ],
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
      return const EmptyState(
        icon: Icons.gavel_outlined,
        title: 'Nothing to judge right now',
        message: 'When battles finish they land here for you to vote on - and '
            'judging earns you points. The most show up during the Daily '
            'Gauntlet, so check back then.',
      );
    }

    return PageView.builder(
      controller: _pageController,
      scrollDirection: Axis.vertical,
      itemCount: _matches!.length,
      onPageChanged: (i) {
        setState(() => _index = i);
        if (i >= _matches!.length - _prefetchWithin) _loadMore();
        _prefetchAhead(i);
      },
      itemBuilder: (context, i) {
        final match = _matches![i];
        return FeedPage(
          key: ValueKey(match.matchId),
          match: match,
          // Plays only when it is the page in view AND this tab is on screen
          // AND the app is foreground - otherwise its audio would keep looping
          // off-tab or in the background.
          isActive: i == _index && widget.isActiveTab && _appForeground,
          onVote: (picks, emojiRatings) =>
              _vote(match.matchId, picks, emojiRatings),
          onCall: _recordCall,
        );
      },
    );
  }
}
