import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/hub_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/tournament/hub_chat.dart';
import '../../widgets/tournament/prize_tab.dart';
import '../../widgets/tournament/weekly_standings_board.dart';
import 'judges_tab.dart';
import 'main_stage_rules_screen.dart';

/// THE MAIN STAGE HUB - the home of the weekly tournament.
///
/// You don't "enter" the tournament here (you qualify by battling all week);
/// this is the destination that gives every ranked battle a point. A persistent
/// top strip (countdown to Thursday + where you stand this week) over four tabs:
///   - Lobby: this week's live chat + founder announcements.
///   - Standings: the qualifying race (top 4 make the Main Stage).
///   - Judges: the panel roster + the "I'll judge" opt-in.
///   - Prize: The Belt, what you win, and the hall of champions.
///
/// Reached by tapping the gold Main Stage card on Home. The weekly data
/// (standings/judges) comes from the tournament-gated sweep, so those tabs show
/// empty states until the system is switched on; the Lobby and Prize tabs work
/// today.
class TournamentHubScreen extends StatefulWidget {
  const TournamentHubScreen({super.key});

  @override
  State<TournamentHubScreen> createState() => _TournamentHubScreenState();
}

class _TournamentHubScreenState extends State<TournamentHubScreen> {
  String? _weekKey;
  bool _roomLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRoom();
  }

  Future<void> _loadRoom() async {
    final wk = await HubService.getHubRoom();
    if (!mounted) return;
    setState(() {
      _weekKey = wk;
      _roomLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final gold = context.palette.reward;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: const Text('The Main Stage',
              style: TextStyle(fontWeight: FontWeight.w900)),
          actions: [
            IconButton(
              icon: const Icon(Icons.help_outline),
              tooltip: 'How the Main Stage works',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const MainStageRulesScreen())),
            ),
          ],
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF0E0B14)),
            Image.asset(
              'assets/home/ranks_background.png',
              fit: BoxFit.fitWidth,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) =>
                  const ColoredBox(color: Color(0xFF0E0B14)),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x66000000), Color(0x11000000), Color(0x88000000)],
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  const _HubHeader(),
                  TabBar(
                    isScrollable: false,
                    indicatorColor: gold,
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white.withValues(alpha: 0.55),
                    labelStyle: const TextStyle(
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                        fontSize: 13),
                    tabs: const [
                      Tab(text: 'LOBBY'),
                      Tab(text: 'RACE'),
                      Tab(text: 'JUDGES'),
                      Tab(text: 'PRIZE'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _roomLoading
                            ? const Center(child: CircularProgressIndicator())
                            : (_weekKey == null
                                ? _lobbyUnavailable()
                                : HubChat(weekKey: _weekKey!)),
                        const WeeklyStandingsBoard(),
                        JudgesTab(weekKey: _weekKey),
                        const PrizeTab(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lobbyUnavailable() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            "Couldn't open the lobby. Pull back and try again.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
          ),
        ),
      );
}

/// The persistent strip above the tabs: the countdown to Thursday's finals and
/// where the viewer stands in this week's race. Reads stats/weeklyQualifier
/// once (standings + cutoff) and ticks the countdown each minute. Renders a
/// minimal line when there's no live race yet (tournament gated off).
class _HubHeader extends StatefulWidget {
  const _HubHeader();

  @override
  State<_HubHeader> createState() => _HubHeaderState();
}

/// The show runs at 6pm Pacific on the cutoff Thursday - cutoffMs is that
/// Thursday 00:00, so the finals start +18h. Matches SHOW_HOUR_PACIFIC.
const int _showHourMs = 18 * 60 * 60 * 1000;

class _HubHeaderState extends State<_HubHeader> {
  Timer? _ticker;
  int? _cutoffMs;
  int? _position;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('stats')
          .doc('weeklyQualifier')
          .get();
      final data = doc.data();
      final me = FirebaseAuth.instance.currentUser?.uid;
      int? position;
      final standings = (data?['standings'] as List?) ?? const [];
      for (var i = 0; i < standings.length; i++) {
        final row = standings[i];
        if (row is Map && row['uid'] == me) {
          position = i + 1;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _cutoffMs = (data?['cutoffMs'] as num?)?.toInt();
        _position = position;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  String _countdown() {
    final c = _cutoffMs;
    if (c == null) return 'Finals run Thursday nights';
    final target = c + _showHourMs;
    final left = target - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) return 'The finals are happening now';
    final mins = left ~/ 60000;
    final days = mins ~/ (60 * 24);
    final hours = (mins ~/ 60) % 24;
    if (days >= 1) return 'Finals in ${days}d ${hours}h';
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h >= 1) return 'Finals in ${h}h ${m}m';
    return 'Finals in ${m}m';
  }

  String? _positionLine() {
    if (_cutoffMs == null) return null; // no live race
    final p = _position;
    if (p == null) return 'Climb into the top 4 to make it';
    if (p <= 4) return "You're #$p — in the top 4. Hold it.";
    if (p <= 8) return "You're #$p — just outside the top 4.";
    return "You're #$p this week. Keep climbing.";
  }

  @override
  Widget build(BuildContext context) {
    final gold = context.palette.reward;
    final text = Theme.of(context).textTheme;
    final posLine = _positionLine();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: const LinearGradient(
            colors: [Color(0xFF2A2210), Color(0xFF15110A)],
          ),
          border: Border.all(color: gold.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Icon(Icons.schedule, color: gold, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _loaded ? _countdown() : 'Loading…',
                    style: text.titleSmall?.copyWith(
                        color: gold, fontWeight: FontWeight.w900),
                  ),
                  if (posLine != null) ...[
                    const SizedBox(height: 1),
                    Text(posLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.8))),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
