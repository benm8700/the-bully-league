import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Today's three quests, shown in the Daily Challenges bottom sheet.
///
/// WHAT THIS IS FOR, and why it is not another scoreboard: the app already
/// answers "am I any good" via rank, and "how am I doing lately" via form.
/// What it never answered is **what should I do right now** - and an app
/// opened with no obvious next action becomes a thirty-second visit. Quests
/// feed the existing points economy rather than standing beside it, so there
/// is no new ladder to keep track of.
///
/// Styled to the app palette (pink accent, gold reward, green for done) so
/// the sheet reads as premium rather than a bare checklist.
class DailyQuests extends StatefulWidget {
  const DailyQuests({super.key});

  @override
  State<DailyQuests> createState() => _DailyQuestsState();
}

class _DailyQuestsState extends State<DailyQuests> {
  List<Map<String, dynamic>> _quests = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getMyQuests')
          .call<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _quests = ((result.data['quests'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _loaded = true;
      });
    } catch (_) {
      // Renders a quiet message rather than an error. A failed nudge must
      // never be the reason the sheet looks broken.
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  /// A fitting icon for each quest type, read from its id prefix.
  IconData _iconFor(String id) {
    if (id.startsWith('judge')) return Icons.gavel;
    if (id.startsWith('win')) return Icons.emoji_events;
    return Icons.mic; // play*
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final accent = context.palette.accent;

    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_quests.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
        child: Column(
          children: [
            Icon(Icons.task_alt, size: 34, color: scheme.onSurfaceVariant),
            const SizedBox(height: 10),
            Text(
              "Couldn't load today's challenges.",
              textAlign: TextAlign.center,
              style: text.bodyMedium,
            ),
          ],
        ),
      );
    }

    final doneCount = _quests.where((q) => q['done'] == true).length;
    final total = _quests.length;
    final allDone = doneCount == total;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: a pink challenge badge, the title, and today's progress.
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.task_alt, color: accent, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Daily Challenges',
                      style: text.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      allDone
                          ? 'All done today - nice work'
                          : '$doneCount of $total complete',
                      style: text.bodyMedium?.copyWith(
                        color: allDone
                            ? context.palette.winner
                            : scheme.onSurfaceVariant,
                        fontWeight: allDone ? FontWeight.w700 : null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          for (final q in _quests) _questCard(context, q),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _questCard(BuildContext context, Map<String, dynamic> q) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final accent = context.palette.accent;
    final gold = context.palette.reward;
    final green = context.palette.winner;

    final done = q['done'] == true;
    final id = q['id'] as String? ?? '';
    final label = q['label'] as String? ?? '';
    final reward = (q['reward'] as num?)?.toInt() ?? 0;
    final progress = (q['progress'] as num?)?.toInt() ?? 0;
    final target = (q['target'] as num?)?.toInt() ?? 1;
    final fill = target > 0 ? (progress / target).clamp(0.0, 1.0) : 0.0;

    final badgeColor = done ? green : accent;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: done
              ? green.withValues(alpha: 0.35)
              : scheme.outlineVariant,
        ),
      ),
      child: Row(
        children: [
          // Type badge - the quest's icon, or a check once complete.
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              done ? Icons.check_rounded : _iconFor(id),
              color: badgeColor,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: done ? scheme.onSurfaceVariant : null,
                  ),
                ),
                const SizedBox(height: 8),
                // Progress: a slim accent bar with a "n / target" caption, or
                // a "Complete" line once done.
                if (done)
                  Text(
                    'Complete',
                    style: text.labelMedium?.copyWith(
                      color: green,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Stack(
                            children: [
                              Container(
                                height: 6,
                                color: scheme.surfaceContainerHighest,
                              ),
                              FractionallySizedBox(
                                widthFactor: fill,
                                child: Container(height: 6, color: accent),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$progress/$target',
                        style: text.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Reward pill - gold, since points are the payoff.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: gold.withValues(alpha: done ? 0.10 : 0.16),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.monetization_on,
                    size: 14,
                    color: gold.withValues(alpha: done ? 0.6 : 1.0)),
                const SizedBox(width: 3),
                Text(
                  '+$reward',
                  style: text.labelMedium?.copyWith(
                    color: gold.withValues(alpha: done ? 0.6 : 1.0),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
