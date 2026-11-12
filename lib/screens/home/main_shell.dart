import 'package:flutter/material.dart';

import '../../core/route_observer.dart';
import '../../widgets/badges/badge_popup.dart';
import '../../widgets/challenge_popup.dart';
import '../../widgets/fame_milestone_popup.dart';
import '../../widgets/feedback_popup.dart';
import '../../widgets/main_stage_alert_bar.dart';
import '../../widgets/rank_change_popup.dart';
import '../../widgets/service_status_banner.dart';
import '../../widgets/tournament_finale_popup.dart';
// WindowLiveBar import removed with the live-bar usage (2026-09-14); restore
// both together to bring the Sixes and Sevens top cue back.
import '../leaderboard/leaderboard_screen.dart';
import '../profile/profile_screen.dart';
import '../vote/my_battles_screen.dart';
import '../vote/watch_feed_screen.dart';
import 'home_screen.dart';

/// The app's top-level navigation.
///
/// Judging is a PERMANENT DESTINATION rather than a button on Home, which
/// is the change that matters here. Votes are the scarce resource in this
/// app - rating only moves as far as a match is judged (see
/// functions/rating.js), so the ladder's whole credibility depends on
/// people voting on battles they weren't in. Burying that behind one of
/// eight identical buttons on a scrolling Home screen made it look
/// optional. A tab makes it a place you can be, and puts it one tap from
/// anywhere in the app.
///
/// Five destinations is the practical ceiling for a bottom bar, so the
/// less-frequent surfaces (tournaments, support, notification settings,
/// account deletion) stay nested inside these rather than competing for a
/// slot.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  /// Lets any screen inside the shell jump to another tab (e.g. Home's "Watch"
  /// door -> the Vote feed). A live callback onto the mounted shell state, so
  /// there is no stale static index to carry across sign-outs. [go] is a no-op
  /// when no shell is mounted.
  static void Function(int index)? _selector;
  static void go(int index) => _selector?.call(index);

  /// Watch = the Judge feed. Since the 2026-11-11 swipe layout it is a pushed
  /// screen, not a tab; go(tabWatch) still opens it.
  static const int tabWatch = 1;

  /// The three swipe pages (2026-11-11, developer's call):
  /// Profile <- Home -> Leaderboard.
  static const int pageProfile = 0;
  static const int pageHome = 1;
  static const int pageLeaderboard = 2;
  static void Function(int page)? _pager;
  static void goPage(int page) => _pager?.call(page);

  /// Ask the shell to run its pop-up queue now (e.g. Home's banner just saw a
  /// new challenge). Safe to call any time: it only shows anything while Home
  /// is the visible screen.
  static VoidCallback? _popupRequest;
  static void requestPopups() => _popupRequest?.call();

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell>
    with RouteAware, WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    MainShell._selector = (i) {
      if (!mounted) return;
      if (i == MainShell.tabWatch) {
        _push(const WatchFeedScreen());
      } else if (i == 2) {
        _push(const MyBattlesScreen());
      } else if (i == 3) {
        _goPage(MainShell.pageLeaderboard);
      } else if (i == 4) {
        _goPage(MainShell.pageProfile);
      }
    };
    MainShell._pager = _goPage;
    MainShell._popupRequest = _runPopups;
    WidgetsBinding.instance.addObserver(this);
    // First run after the first frame (a dialog needs a mounted route).
    WidgetsBinding.instance.addPostFrameCallback((_) => _runPopups());
  }

  // ---------------------------------------------------------------------
  // THE POP-UP QUEUE (2026-11-11, developer's call).
  //
  // One place decides when pop-ups appear, so they never stack and never
  // land on top of a battle. It runs:
  //  - on launch,
  //  - every time Home becomes visible again (back from a battle, Judge,
  //    Profile... - RouteAware.didPopNext),
  //  - when the app comes back to the foreground on Home,
  //  - when Home's banner sees a new challenge (MainShell.requestPopups).
  // It only shows anything while Home is the TOP screen, and re-checks that
  // before every pop-up. The other pop-ups each mark themselves "seen" on
  // the server when asked, so asking only while Home is on screen is what
  // stops one being claimed and then lost behind a battle. Anything not yet
  // shown simply waits for the next time Home is on screen.
  //
  // Order: the CHALLENGE first (the only one that expires; accepting it
  // goes into a battle, so the queue stops there and resumes when they come
  // back to Home), then the tournament finale, rank, badges, fame, feedback.
  // ---------------------------------------------------------------------
  bool _popupsRunning = false;
  bool _popupsAgain = false;
  ModalRoute<dynamic>? _route;

  bool get _homeOnTop => mounted && (_route?.isCurrent ?? false);

  Future<void> _runPopups() async {
    if (_popupsRunning) {
      _popupsAgain = true;
      return;
    }
    _popupsRunning = true;
    try {
      do {
        _popupsAgain = false;
        if (!mounted || !_homeOnTop) return;
        final accepted = await ChallengePopup.maybeShow(context);
        if (accepted) return; // heading into a battle; resume on return
        if (!mounted || !_homeOnTop) return;
        await TournamentFinalePopup.maybeShow(context);
        if (!mounted || !_homeOnTop) return;
        await RankChangePopup.maybeShow(context);
        if (!mounted || !_homeOnTop) return;
        await BadgePopup.maybeShow(context);
        if (!mounted || !_homeOnTop) return;
        await FameMilestonePopup.maybeShow(context);
        if (!mounted || !_homeOnTop) return;
        // Last, and only once ever: after a few real battles, ask how we can
        // make it more fun. Lowest priority so it never pre-empts anything.
        await FeedbackPopup.maybeShow(context);
      } while (_popupsAgain && mounted);
    } finally {
      _popupsRunning = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null && route != _route) {
      if (_route != null) appRouteObserver.unsubscribe(this);
      _route = route;
      appRouteObserver.subscribe(this, route);
    }
  }

  /// Back on Home after a pushed screen (a battle, Judge, Profile...).
  @override
  void didPopNext() {
    // A beat after the pop animation, so the pop-up doesn't fight it.
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _runPopups();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _runPopups();
  }

  void _push(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  /// TAP-ONLY (2026-11-11): the swipe pager was tried and rejected by the
  /// developer (too easy to trigger by accident, made Home feel skittish).
  /// Profile and the Leaderboard are now ordinary pushed screens with a back
  /// arrow. Home is the only page.
  void _goPage(int page) {
    if (!mounted) return;
    if (page == MainShell.pageProfile) {
      _push(const ProfileScreen());
    } else if (page == MainShell.pageLeaderboard) {
      _push(const LeaderboardScreen());
    }
  }

  @override
  void dispose() {
    MainShell._selector = null;
    MainShell._pager = null;
    MainShell._popupRequest = null;
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Column(
        children: [
          // Above Home: an outage affects every screen. Renders nothing when
          // there is no notice.
          ServiceStatusBanner(),
          // Pulls key Main Stage people in. Renders nothing for everyone else.
          MainStageAlertBar(),
          Expanded(child: HomeScreen()),
        ],
      ),
    );
  }
}
