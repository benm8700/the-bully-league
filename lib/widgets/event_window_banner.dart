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
            onPressed: () => _showTournamentInfo(context, config),
          ),
          overlay: const SizedBox.shrink(),
        );
      },
    );
  }

  /// Explains the nightly tournament: what it is, the rules, the prize, and
  /// the 2x bonus. Opened by the "?" on the card.
  void _showTournamentInfo(BuildContext context, EventWindowConfig config) {
    final hours =
        '${_hour12(config.startHourPacific)}-${_hour12(config.endHourPacific)} Pacific';
    final body = Theme.of(context).textTheme.bodyMedium;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(config.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'The nightly tournament - $hours, every night. One hour, one '
                'crowd, one champion.',
                style: body,
              ),
              const SizedBox(height: 16),
              _infoHeading(context, 'How it works'),
              Text(
                'Hop in any time during the hour - everyone starts at 0 wins. '
                "You're paired with someone who has the same number of wins as "
                "you. Win, and you move up. Lose, and you're out - but you can "
                'stick around to watch and vote. Keep winning to climb, and the '
                'last one standing takes the crown. If the clock runs out '
                "first, whoever's climbed highest wins it.",
                style: body,
              ),
              const SizedBox(height: 16),
              _infoHeading(context, 'The prize'),
              Text(
                'Prestige, and prizes when they are on the line. It is free to '
                'enter and the champion takes the night. Bigger cash-prize '
                'events run on top from time to time.',
                style: body,
              ),
              const SizedBox(height: 16),
              _infoHeading(context, 'The bonus'),
              Text(
                'Everything counts double during the hour - 2x points on every '
                'battle AND every vote.',
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

  String _hour12(int hour24) {
    final h = hour24 % 12 == 0 ? 12 : hour24 % 12;
    return '$h${hour24 < 12 ? 'am' : 'pm'}';
  }
}
