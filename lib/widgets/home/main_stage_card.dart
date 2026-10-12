import 'package:flutter/material.dart';

import '../../screens/tournament/tournament_hub_screen.dart';
import '../../theme/app_theme.dart';
import 'hero_mode_card.dart';

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

    return HeroModeCard(
      asset: 'assets/home/tournament_hero.png',
      glow: context.palette.reward, // gold - the event/tournament colour
      aspectRatio: kHeroPillAspect, // matched to the Basement pill
      scrim: false, // baked art used as-is
      onTap: openHub,
      topRight: IconButton(
        icon: const Icon(Icons.help_outline),
        iconSize: 28,
        color: Colors.white,
        tooltip: 'How the Main Stage works',
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.42),
          padding: const EdgeInsets.all(6),
        ),
        onPressed: () => _showMainStageInfo(context),
      ),
      overlay: const SizedBox.shrink(),
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
                'The weekly finals - the biggest stage in the league. Four '
                'roasters battle live, a panel of judges decides, and the '
                'champion takes The Belt.',
                style: body,
              ),
              const SizedBox(height: 16),
              _infoHeading(context, 'How you get here'),
              Text(
                "You don't enter - you qualify by battling in The Basement all "
                'week. The top 3 roasters by skill lock in a seat. The 4th is a '
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
