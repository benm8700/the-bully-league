import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// Today's three quests.
///
/// WHAT THIS IS FOR, and why it is not another scoreboard: the app
/// already answers "am I any good" via rank, and "how am I doing lately"
/// via form. What it never answered is **what should I do right now** -
/// and an app opened with no obvious next action becomes a thirty-second
/// visit. Quests feed the existing points economy rather than standing
/// beside it, so there is no new ladder to keep track of.
///
/// Deliberately compact. This is a nudge on the way to a battle, not a
/// screen of its own - three lines that can be read in a glance and
/// ignored by anyone who already knows what they came for.
class DailyQuests extends StatefulWidget {
  const DailyQuests({super.key});

  @override
  State<DailyQuests> createState() => _DailyQuestsState();
}

class _DailyQuestsState extends State<DailyQuests> {
  List<Map<String, dynamic>> _quests = const [];

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
      });
    } catch (_) {
      // Renders nothing rather than an error. A failed nudge must never
      // be the reason Home looks broken.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_quests.isEmpty) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final doneCount = _quests.where((q) => q['done'] == true).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            // Says the state up front, so someone who has finished can
            // stop reading immediately.
            doneCount == _quests.length
                ? 'Today: all done'
                : 'Today ($doneCount/${_quests.length})',
            style: text.labelMedium,
          ),
          const SizedBox(height: 6),
          ..._quests.map((q) {
            final done = q['done'] == true;
            final progress = (q['progress'] as num?)?.toInt() ?? 0;
            final target = (q['target'] as num?)?.toInt() ?? 1;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    done ? Icons.check_circle : Icons.circle_outlined,
                    size: 16,
                    // A finished quest is dimmed rather than removed, so
                    // the list does not reshuffle under someone's eyes
                    // between glances.
                    color: done ? null : Theme.of(context).disabledColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      q['label'] as String? ?? '',
                      style: done
                          ? text.bodySmall?.copyWith(
                              decoration: TextDecoration.lineThrough,
                              color: Theme.of(context).disabledColor,
                            )
                          : text.bodySmall,
                    ),
                  ),
                  Text(
                    done ? '+${q['reward']}' : '$progress/$target',
                    style: text.bodySmall,
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
