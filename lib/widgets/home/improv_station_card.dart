import 'package:flutter/material.dart';

import 'hero_mode_card.dart';

/// IMPROV STATION - a FULL hero pill on Home, under the other modes. A
/// prompt-based comedy showcase (both comedians riff the same prompt, blind,
/// crowd-voted): a different, lower-pressure outlet than roasting a stranger.
///
/// TEAL identity - distinct from the pink Basement, gold Main Stage, and purple
/// Challenge-a-Friend, so the four modes read as four things. No baked art yet,
/// so HeroModeCard's gradient fallback renders with a live-overlay title; drop
/// an `assets/home/improv_hero.png` in later for a baked-art pill, no code
/// change. [onStart] runs the normal start flow (entitlement -> consent ->
/// pre-match -> improv queue).
class ImprovStationCard extends StatelessWidget {
  const ImprovStationCard({super.key, required this.onStart});

  final VoidCallback onStart;

  static const _teal = Color(0xFF2BC4B0);

  @override
  Widget build(BuildContext context) {
    return HeroModeCard(
      asset: 'assets/home/improv_hero.png', // not present yet -> gradient
      glow: _teal,
      aspectRatio: kHeroPillAspect,
      scrim: false,
      onTap: onStart,
      topRight: IconButton(
        icon: const Icon(Icons.help_outline),
        iconSize: 28,
        color: Colors.white,
        tooltip: 'About Improv Station',
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.42),
          padding: const EdgeInsets.all(6),
        ),
        onPressed: () => _showInfo(context),
      ),
      center: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          HeroTitle('IMPROV STATION', color: _teal),
          SizedBox(height: 4),
          HeroSubtitle('SAME PROMPT. FUNNIEST WINS.'),
        ],
      ),
      overlay: const SizedBox.shrink(),
    );
  }

  void _showInfo(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyMedium;
    Widget heading(String label) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _teal,
                ),
          ),
        );
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Improv Station'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Not a roast - a showcase. You and a stranger get the SAME '
                'prompt each round and riff a quick one-liner on it.',
                style: body,
              ),
              const SizedBox(height: 16),
              heading('How it works'),
              Text(
                'Three prompts, 15 seconds each. You and your opponent get the '
                'same prompt at the same time and riff - you CANNOT see or '
                "hear each other, so nobody steals anybody's angle.",
                style: body,
              ),
              const SizedBox(height: 16),
              heading('How you win'),
              Text(
                'The crowd watches both sets and votes who was funnier. It '
                'climbs your rank, but it has its own skill rating and does '
                'not feed the Main Stage.',
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
}
