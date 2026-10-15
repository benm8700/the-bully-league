import 'package:flutter/material.dart';

import '../../screens/friends/challenge_screen.dart';
import 'hero_mode_card.dart';

/// Battle a Friend, promoted to a FULL hero pill on Home (same size/shape/glow
/// as the Basement and Main Stage pills), sitting directly under them.
///
/// This is a deliberate growth bet: "challenge your buddy" is the most reliable
/// way to start a battle in a thin pool AND the seed of the invite-by-text loop,
/// so it earns a headline slot rather than a quiet link down in the nav list.
///
/// PURPLE identity - distinct from the pink Basement hero and the gold Main
/// Stage, and consistent with the purple "Send challenge" action inside the
/// screen itself. No baked art yet, so HeroModeCard's gradient fallback renders
/// and the title is a live overlay; drop an `assets/home/friend_hero.png` in
/// later and it becomes a baked-art pill like the other two with no code change.
class FriendBattleCard extends StatelessWidget {
  const FriendBattleCard({super.key});

  @override
  Widget build(BuildContext context) {
    final purple = Theme.of(context).colorScheme.secondary;
    return HeroModeCard(
      asset: 'assets/home/friend_hero.png', // not present yet -> gradient
      glow: purple,
      aspectRatio: kHeroPillAspect, // same size as the other two pills
      scrim: false, // centred title over the gradient; no bottom overlay to dim
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ChallengeScreen()),
      ),
      topRight: IconButton(
        icon: const Icon(Icons.help_outline),
        iconSize: 28,
        color: Colors.white,
        tooltip: 'About Challenge a Friend',
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.42),
          padding: const EdgeInsets.all(6),
        ),
        onPressed: () => _showInfo(context, purple),
      ),
      // Centred title/subtitle like the baked wordmarks on the other two.
      center: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HeroTitle('CHALLENGE A FRIEND', color: purple),
          const SizedBox(height: 4),
          const HeroSubtitle('CALL OUT ANYONE BY NAME'),
        ],
      ),
      overlay: const SizedBox.shrink(),
    );
  }

  void _showInfo(BuildContext context, Color accent) {
    final body = Theme.of(context).textTheme.bodyMedium;
    Widget heading(String label) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: accent,
                ),
          ),
        );
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Challenge a Friend'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Skip the random queue and call out someone you know by '
                'username - they get a challenge, and you battle whenever you '
                'are both ready.',
                style: body,
              ),
              const SizedBox(height: 16),
              heading('Just for fun'),
              Text(
                'A friend battle is a private scrimmage: it does not affect '
                'your rank, and it is not recorded, judged, or posted. Pure '
                'bragging rights.',
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
