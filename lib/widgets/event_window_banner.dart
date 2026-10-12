import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/services/event_window.dart';
import '../screens/tournament/tournament_hub_screen.dart';
import '../theme/app_theme.dart';
import 'home/hero_mode_card.dart';

/// The Main Stage hero card on Home - the front door to the tournament HUB.
///
/// A clean full-bleed image pill, matched to the Basement (Roast a Stranger)
/// hero: the baked "MAIN STAGE" artwork, a gold glow, a "?" explainer, and the
/// whole card taps through to the hub (where the countdown, standings, lobby,
/// judges and prize live). No countdown / chips / CTA on the card itself - the
/// old "ENTER TOURNAMENT" button was redundant once the whole card opens the
/// hub, so the two Home heroes now read as a matched pair of equal size.
///
/// Reads config/eventWindow only to decide whether to show at all (and to fill
/// the "?" explainer). Renders nothing when disabled or unreadable, so a
/// switched-off promo never makes Home look wrong.
class EventWindowBanner extends StatelessWidget {
  const EventWindowBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('config')
          .doc('eventWindow')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const SizedBox.shrink();
        // Falls back to documented defaults if the doc doesn't exist yet.
        final config = EventWindowConfig.fromMap(snapshot.data?.data());
        if (!config.enabled) return const SizedBox.shrink();

        void openHub() => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TournamentHubScreen()),
            );

        return HeroModeCard(
          asset: 'assets/home/tournament_hero.png',
          glow: context.palette.reward, // gold - the event/tournament colour
          aspectRatio: kHeroPillAspect, // matched to the Basement pill
          scrim: false, // baked art used as-is, no overlay to keep readable
          onTap: openHub,
          topRight: IconButton(
            icon: const Icon(Icons.help_outline),
            iconSize: 28,
            color: Colors.white,
            tooltip: 'How the tournament works',
            style: IconButton.styleFrom(
              backgroundColor: Colors.black.withValues(alpha: 0.42),
              padding: const EdgeInsets.all(6),
            ),
            onPressed: () => _showTournamentInfo(context),
          ),
          overlay: const SizedBox.shrink(),
        );
      },
    );
  }

  /// Explains the Main Stage: what it is, how you qualify through the week, and
  /// the wild-card draw. Opened by the "?" on the card. Deliberately high-level
  /// - the finals' format (your clock, interrupts) lives in the hub's rules
  /// screen. The wild-card odds are described by their LEVERS (play + judge),
  /// never the exact weighting, matching the app's hidden-criteria style.
  void _showTournamentInfo(BuildContext context) {
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
                'wild card: qualify for the week, then the more you play AND '
                'judge, the better your odds of getting pulled in.',
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
