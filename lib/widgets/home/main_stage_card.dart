import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../screens/tournament/tournament_hub_screen.dart';
import '../../theme/app_theme.dart';
import 'home_action_card.dart';

/// The Main Stage hero card on Home - the permanent front door to the WEEKLY
/// tournament hub.
///
/// A clean full-bleed image pill (baked "MAIN STAGE" art, gold glow, a "?"
/// explainer, whole-card tap to the hub), matched in size to the Basement pill.
///
/// It is NOT tied to the daily 6-7pm window any more: the weekly Main Stage is
/// its own thing, the countdown to Thursday's finals lives in the hub, and the
/// daily "power hour" has its own slim strip (DailyWindowStrip). Always shown -
/// the hub handles its own empty states before the tournament is switched on.
class MainStageCard extends StatelessWidget {
  const MainStageCard({super.key});

  @override
  Widget build(BuildContext context) {
    void openHub() => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TournamentHubScreen()),
        );

    // Watches the tournament flag so a "COMING SOON" badge shows while it is
    // switched off (which it is now). Everything underneath - the card, the
    // hub, all the features - stays fully intact and tappable; this is only a
    // reminder to users that the monthly Main Stage is not live yet, and it
    // disappears automatically the moment config/tournament.enabled flips true.
    //
    // Same slim side margin as the Play/Watch cards so all three line up.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('config')
          .doc('tournament')
          .snapshots(),
      builder: (context, snap) {
        final enabled = snap.data?.data()?['enabled'] == true;
        // Same shared card as Play/Watch, so all three are identical in size.
        return HomeActionCard(
          asset: 'assets/home/tournament_hero.png',
          accent: context.palette.reward, // gold - the event colour
          onTap: openHub,
          topRight: IconButton(
            icon: const Icon(Icons.help_outline),
            iconSize: 22,
            color: Colors.white,
            tooltip: 'How the Main Stage works',
            style: IconButton.styleFrom(
              backgroundColor: Colors.black.withValues(alpha: 0.42),
              padding: const EdgeInsets.all(5),
              minimumSize: const Size(0, 0),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => _showMainStageInfo(context),
          ),
          // Sits just below the baked "MAIN STAGE" title so it never covers it.
          center: enabled ? null : _comingSoonBadge(context),
          centerAlignment: const Alignment(0, 0.55),
        );
      },
      ),
    );
  }

  /// A dark gold-rimmed "COMING SOON" pill, shown over the card while the
  /// tournament is switched off.
  Widget _comingSoonBadge(BuildContext context) {
    final gold = context.palette.reward;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: gold.withValues(alpha: 0.9), width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 15, color: gold),
          const SizedBox(width: 6),
          Text(
            'COMING SOON',
            style: TextStyle(
              color: gold,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  /// Explains the Main Stage: what it is, how you qualify through the week, and
  /// the wild-card draw. Deliberately high-level - the finals' format (your
  /// clock, interrupts) lives in the hub's rules screen. The wild-card odds are
  /// described by their LEVERS (play + vote), never the exact weighting.
  void _showMainStageInfo(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyMedium;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('The Main Stage'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'The monthly finals - the biggest stage in the league. Four '
                'roasters battle live, a panel of judges decides, and the '
                'champion takes The Belt. One big night, hyped all month.',
                style: body,
              ),
              const SizedBox(height: 16),
              _infoHeading(context, 'How you get here'),
              Text(
                "You don't enter - you qualify by battling in The Basement all "
                'month. The top 3 roasters by skill lock in a seat. The 4th is a '
                'wild card: the more you play and vote on other matches, the '
                'better your odds of getting selected.',
                style: body,
              ),
              const SizedBox(height: 16),
              _infoHeading(context, 'The night'),
              Text(
                'The four face off live, one battle at a time - the top seed '
                'even gets to call out who they want first. The judges decide '
                'each one, and the last roaster standing is champion.',
                style: body,
              ),
              const SizedBox(height: 16),
              _infoHeading(context, 'The prize'),
              Text(
                'The Belt - the one title you lose the moment someone else wins '
                '- plus a permanent Champion badge. Bigger, real prizes come '
                'later; for now it is the prestige, and the whole room watching '
                'you take it.',
                style: body,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Widget _infoHeading(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: context.palette.reward,
            ),
      ),
    );
  }
}
