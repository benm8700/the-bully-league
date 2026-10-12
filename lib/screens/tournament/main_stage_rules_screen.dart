import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// How a MAIN STAGE battle works - the weekly-finals chess-clock format, which
/// is deliberately NOT the everyday 3x15s alternating format the main "How it
/// works" screen describes. A finalist should never meet these rules for the
/// first time live on stage, so this is reachable from the Main Stage screen
/// (an info icon, always; an inline link right by "Play your match").
///
/// Intentionally NOT a forced tutorial - it's here to read when you want it.
/// Numbers are kept soft ("about a minute", "a beat") because the real timings
/// are console-tunable config; the MECHANICS, which don't change, are stated
/// precisely.
class MainStageRulesScreen extends StatelessWidget {
  const MainStageRulesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final gold = context.palette.reward;
    return Scaffold(
      appBar: AppBar(title: const Text('How the Main Stage works')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            'The finals are a different beast.',
            style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800, color: gold),
          ),
          const SizedBox(height: 8),
          Text(
            'No fixed turns here. You each get your own clock, and you control '
            'when you talk and when you hand it over. One mic is live at a '
            'time. Learn the rhythm before you step up.',
            style: text.bodyMedium?.copyWith(height: 1.4),
          ),
          const _MsRule(
            icon: Icons.timer_outlined,
            title: 'Your clock',
            body: 'You each get a fixed talk budget - about a minute. It only '
                'ticks while YOU hold the mic. Talk as long or as little as you '
                'want; whatever you don\'t use banks for later. When both '
                'clocks hit zero, the battle is over.',
          ),
          const _MsRule(
            icon: Icons.swap_horiz,
            title: 'Pass the mic',
            body: 'Done with your bit? Yield. The mic passes to your opponent, '
                'free - it costs you nothing. Land your lines, hand it over, '
                'and think up your next ones while they sweat.',
          ),
          const _MsRule(
            icon: Icons.bolt,
            title: 'Interrupts - your 2 steals',
            body: 'You get two interrupts a battle. Cut in while your opponent '
                'has the mic and you steal the floor - but it costs you: one of '
                'your two steals, and it starts your own clock. Save them for '
                'the perfect comeback, not for spam.',
          ),
          const _MsRule(
            icon: Icons.record_voice_over_outlined,
            title: 'They get to finish',
            body: 'An interrupt can\'t gag anyone mid-punchline. When you cut '
                'in, your opponent gets a quick beat to land their line before '
                'the mic flips to you - their clock flashes red and they feel a '
                'buzz: "someone\'s coming, say it NOW." You can steal the '
                'spotlight; you can never steal the joke.',
          ),
          const _MsRule(
            icon: Icons.hourglass_bottom,
            title: 'No stalling',
            body: 'Take the mic and you have a few seconds to start talking, or '
                'it bounces back to your opponent. There\'s no hiding in a '
                '"you go first" standoff.',
          ),
          const _MsRule(
            icon: Icons.flag_outlined,
            title: 'Out of time',
            body: 'If your opponent has burned their whole clock and the stage '
                'is yours, land one more - or just end it. Nothing is lost by '
                'ending early; your clock would run out anyway.',
          ),
          const _MsRule(
            icon: Icons.gavel_outlined,
            title: 'Who wins',
            body: 'Same as any battle: the judges decide who was funnier. The '
                'clock is just how you get your reps in - what you DO with your '
                'time is what they score.',
          ),
        ],
      ),
    );
  }
}

class _MsRule extends StatelessWidget {
  const _MsRule({required this.icon, required this.title, required this.body});

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
