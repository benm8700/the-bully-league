import 'package:flutter/material.dart';

import '../match/pre_match_screen.dart';
import '../match/recording_consent_screen.dart';

/// The Elite League: a rank-gated showcase only Featured Talent + GOAT reach.
///
/// It exists as its own screen rather than a plain queue button for one
/// reason - the liquidity is, and for a long while will be, terrible.
/// Nobody has ground to 5000 XP yet, so an elite player who taps "find a
/// match" and sits alone would read the mode as broken. Framing it FIRST as
/// something you EARNED - "you're one of the few, most legends haven't made
/// it here yet" - turns an empty queue into a flex. That is the developer's
/// explicit call (CLAUDE.md): the empty state should feel like being early
/// to something exclusive, not like a dead room.
///
/// The format is punchier than ranked (2 rounds x 20s, less prep) - the best
/// comedians putting on the most watchable show. Those numbers live in
/// config/matchSettings (perMode.elite) and are stamped server-side, so the
/// copy here quotes the intent rather than hardcoding the clock.
class EliteLeagueScreen extends StatelessWidget {
  const EliteLeagueScreen({super.key});

  // Gold, the same "prestige / prizes" signal the tournament surfaces use -
  // deliberately NOT the pink primary, so the elite league reads as its own
  // rarefied thing.
  static const _gold = Color(0xFFF4C838);
  static const _deepGold = Color(0xFFB8860B);

  Future<void> _enter(BuildContext context) async {
    // Recording consent is NOT skipped for elite, despite the mode being
    // "stripped down": all-party recording consent is a legal requirement
    // (CLAUDE.md's Recording Consent item), not friction to trim. The
    // tutorial gate and the monetization/subscribe check ARE skipped - an
    // elite player has completed the tutorial long ago (you cannot reach
    // this rank without it) and access here is by RANK, not by tier.
    final consented = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RecordingConsentScreen()),
    );
    if (consented != true || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PreMatchScreen(mode: 'elite')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: const Color(0xFF120D08),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Elite League'),
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              // The crest, glowing - the whole appeal is that you're the kind
              // of player this is for.
              Center(
                child: Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [_gold.withValues(alpha: 0.32), Colors.transparent],
                    ),
                  ),
                  child: const Icon(Icons.emoji_events_rounded,
                      color: _gold, size: 84),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'THE ELITE LEAGUE',
                textAlign: TextAlign.center,
                style: text.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Featured Talent & GOAT only',
                textAlign: TextAlign.center,
                style: text.titleSmall?.copyWith(
                  color: _gold,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 22),
              // The flex: being early IS the reward while the field is thin.
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _gold.withValues(alpha: 0.35)),
                ),
                child: Column(
                  children: [
                    Text(
                      "You made it to the top of the ladder. Almost nobody "
                      "has - so the arena is quiet for now. That is the point: "
                      "you're early to the most exclusive room in the app.",
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.85),
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 14),
                    // The format, punchier than ranked. Three quick chips.
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: const [
                        _FormatChip(icon: Icons.bolt, label: '2 rounds'),
                        _FormatChip(icon: Icons.timer_outlined, label: '20s a turn'),
                        _FormatChip(
                            icon: Icons.local_fire_department,
                            label: 'less prep, more punch'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // A gold enter button, matching the prestige framing.
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: const LinearGradient(
                    colors: [_gold, _deepGold],
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _enter(context),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'Enter the arena',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "If no other legend is around, your challenge stays out there "
                "for the next one to answer - you don't have to wait on the "
                "screen.",
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FormatChip extends StatelessWidget {
  const _FormatChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: EliteLeagueScreen._gold),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }
}
