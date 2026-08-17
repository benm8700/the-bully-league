import 'package:flutter/material.dart';

import '../../widgets/rank_change_popup.dart';
import '../../widgets/service_status_banner.dart';
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

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Checked here rather than on Home so it fires once per app launch,
    // not every time someone taps back to the first tab. Deferred past the
    // first frame because it shows a dialog and needs a mounted route to
    // put one on.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) RankChangePopup.maybeShow(context);
    });
  }

  /// Kept alive across tab switches via IndexedStack rather than rebuilt,
  /// so the vote queue doesn't refetch and the live tallies don't drop
  /// their listeners every time someone glances at another tab.
  static const _screens = [
    HomeScreen(),
    WatchFeedScreen(embedded: true),
    MyBattlesScreen(embedded: true),
    LeaderboardScreen(embedded: true),
    ProfileScreen(embedded: true),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Above the tabs rather than on Home, deliberately: an outage
      // affects every screen, and someone stuck on the Judge tab watching
      // nothing load is exactly who needs to be told it is us and not
      // them. It renders nothing at all when there is no notice, so it
      // costs a zero-height widget the rest of the time.
      body: Column(
        children: [
          const ServiceStatusBanner(),
          Expanded(child: IndexedStack(index: _index, children: _screens)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.sports_mma_outlined),
            selectedIcon: Icon(Icons.sports_mma),
            label: 'Battle',
          ),
          NavigationDestination(
            icon: Icon(Icons.gavel_outlined),
            selectedIcon: Icon(Icons.gavel),
            label: 'Judge',
          ),
          NavigationDestination(
            icon: Icon(Icons.emoji_events_outlined),
            selectedIcon: Icon(Icons.emoji_events),
            label: 'My Battles',
          ),
          NavigationDestination(
            icon: Icon(Icons.leaderboard_outlined),
            selectedIcon: Icon(Icons.leaderboard),
            label: 'Ranks',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
