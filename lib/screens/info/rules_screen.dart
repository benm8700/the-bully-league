import 'package:flutter/material.dart';

/// The rules of the game - reachable from Home. Plain, on-brand, and short:
/// a new player wants to know how a battle works, how they win, and what
/// crosses the line, without wading through the Terms of Service.
///
/// Deliberately NOT a legal document (that lives at the website /legal
/// page). This is the friendly "how do I play" version.
class RulesScreen extends StatelessWidget {
  const RulesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rules')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: const [
          _Rule(
            icon: Icons.sports_mma_outlined,
            title: 'The battle',
            body: 'You are matched one-on-one. First comes a short warmup - '
                'both mics open, size each other up. Then you take turns: '
                'when it is your turn you roast, and your opponent\'s mic is '
                'muted. Turns are short, so land the joke fast. A few rounds '
                'and it is done.',
          ),
          _Rule(
            icon: Icons.how_to_vote_outlined,
            title: 'How you win',
            body: 'The crowd decides. People watch the battle and vote for who '
                'was funnier - most votes wins. A tie counts as neither a win '
                'nor a loss. It is skill, not luck: win, and you climb.',
          ),
          _Rule(
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
          _Rule(
            icon: Icons.local_fire_department_outlined,
            title: 'Sixes and Sevens',
            body: 'The nightly tournament, 6-7pm Pacific. It is the main event '
                'and where the prestige and prizes are. Check in when it '
                'opens, and battle through the bracket. Miss it and you can '
                'still find a one-on-one any time.',
          ),
          _Rule(
            icon: Icons.emoji_emotions_outlined,
            title: 'What flies, and what doesn\'t',
            body: 'This is a comedy platform. Offensive jokes, hard roasts, '
                'going for the throat - that is the whole point, and it is all '
                'fair game. What is NOT: hate or targeted harassment that '
                'is not in service of the joke, and anything explicit on '
                'camera. If someone crosses that line, report them - the '
                'report button is on every battle.',
          ),
          _Rule(
            icon: Icons.movie_outlined,
            title: 'Recording & clips',
            body: 'Your battles are recorded and can become shareable clips '
                '(practice matches are the exception - those are never '
                'recorded). You consent to that before each match.',
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
