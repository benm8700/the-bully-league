import 'package:flutter/material.dart';

import '../onboarding/tutorial_screen.dart';
import '../support/support_screen.dart';

/// "How it works" - the single Home entry point that replaced the separate
/// Rules button and help menu. Plain, on-brand, and short: a new player wants
/// to know how a battle works, how they win, and what crosses the line,
/// without wading through the Terms of Service.
///
/// At the BOTTOM sit the two things the old help menu used to offer: the
/// interactive demo ("how a battle works" - the practice walkthrough), and a
/// support link. So one box now covers rules + demo + support.
///
/// Deliberately NOT a legal document (that lives at the website /legal page).
/// This is the friendly "how do I play" version.
///
/// (Class name kept as RulesScreen to avoid churn; user-facing title is
/// "How it works".)
class RulesScreen extends StatelessWidget {
  const RulesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('How it works')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          const _Rule(
            icon: Icons.sports_mma_outlined,
            title: 'The battle',
            body: 'You are matched one-on-one. First comes a short warmup - '
                'both mics open, size each other up. Then you take turns: '
                'when it is your turn you roast, and your opponent\'s mic is '
                'muted. Turns are short, so land the joke fast. A few rounds '
                'and it is done.',
          ),
          const _Rule(
            icon: Icons.how_to_vote_outlined,
            title: 'How you win',
            body: 'The crowd decides. People watch the battle and vote for who '
                'was funnier - most votes wins. A tie counts as neither a win '
                'nor a loss. It is skill, not luck: win, and you climb.',
          ),
          const _Rule(
            icon: Icons.videocam_outlined,
            title: 'Your intro',
            body: 'Record a 60-second "tell me about yourself" - it is '
                'required before you can battle, and it matters more than it '
                'looks. It is how your opponent and the crowd get to know you '
                'before a single word is thrown, and it sets the tone for the '
                'whole battle. Take it seriously and put yourself out there - '
                'a blank, say-nothing intro just makes for a flat, '
                'forgettable matchup.',
          ),
          const _Rule(
            icon: Icons.local_fire_department_outlined,
            title: 'Sixes and Sevens',
            body: 'The nightly tournament, 6-7pm Pacific. It is the main event '
                'and where the prestige and prizes are. Check in when it '
                'opens, and battle through the bracket. Miss it and you can '
                'still find a one-on-one any time.',
          ),
          const _Rule(
            icon: Icons.emoji_emotions_outlined,
            title: 'What flies, and what doesn\'t',
            body: 'This is a comedy platform. Offensive jokes, hard roasts, '
                'going for the throat - that is the whole point, and it is all '
                'fair game. What is NOT: hate or targeted harassment that '
                'is not in service of the joke, and anything explicit on '
                'camera. If someone crosses that line, report them - the '
                'report button is on every battle.',
          ),
          const _Rule(
            icon: Icons.movie_outlined,
            title: 'Recording & clips',
            body: 'Your battles are recorded and can become shareable clips '
                '(practice matches are the exception - those are never '
                'recorded). You consent to that before each match.',
          ),

          // The interactive demo, at the bottom - the old "how a battle
          // works" menu item. It runs the real turn machinery (countdown,
          // the clock, End My Turn) against a simulated opponent, joining no
          // channel, so it is free to run and safe to replay any time.
          const SizedBox(height: 36),
          const Divider(),
          const SizedBox(height: 20),
          Row(
            children: [
              Icon(Icons.play_circle_outline, size: 22, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text('See it in action',
                    style:
                        text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Walk through a real practice round - the countdown, the turn '
            'clock, ending your turn - against a simulated opponent. No one '
            'else is there and nothing is recorded.',
            style: text.bodyMedium?.copyWith(height: 1.4),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const TutorialScreen(replay: true),
              ),
            ),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
            icon: const Icon(Icons.school_outlined, size: 20),
            label: const Text('Walk me through a battle'),
          ),

          // Support lives here now too (it used to share the help menu).
          const SizedBox(height: 28),
          Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SupportScreen(),
                ),
              ),
              child: const Text('Support & feedback'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    style: text.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(body, style: text.bodyMedium?.copyWith(height: 1.4)),
        ],
      ),
    );
  }
}
