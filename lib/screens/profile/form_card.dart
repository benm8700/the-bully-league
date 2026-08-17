import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../core/services/entitlement_service.dart';

/// A player's own competitive form, built on the rating history recorded
/// at each finalization.
///
/// WHY FORM RATHER THAN TOTALS. Wins and losses are already on the
/// profile, and a career total answers a question nobody is asking. What
/// a competitive player genuinely cannot see anywhere is whether they are
/// currently climbing or sliding - which is the question a ladder
/// provokes and the reason they opened this screen.
///
/// GATED FROM THE START, not added free and restricted later. CLAUDE.md
/// designates stats a subscriber feature, and clawing back something
/// people already have is the most damaging pricing move available. While
/// enforcement is switched off everyone reads as trial, so nobody is
/// currently shut out - but the boundary is already in the right place.
class FormCard extends StatefulWidget {
  const FormCard({super.key});

  @override
  State<FormCard> createState() => _FormCardState();
}

class _FormCardState extends State<FormCard> {
  bool _loading = true;
  bool _entitled = true;
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _entries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entitlement = await EntitlementService().current();
      // Trial counts: the trial is full access by definition.
      final entitled =
          entitlement.state == 'subscriber' || entitlement.state == 'trial';
      if (!entitled) {
        if (mounted) {
          setState(() {
            _entitled = false;
            _loading = false;
          });
        }
        return;
      }
      final result = await FirebaseFunctions.instance
          .httpsCallable('getMyRatingHistory')
          .call<Map<String, dynamic>>({'limit': 10});
      if (!mounted) return;
      setState(() {
        _summary = (result.data['summary'] as Map?)?.cast<String, dynamic>();
        _entries = ((result.data['entries'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _loading = false;
      });
    } catch (_) {
      // Stats are a nice-to-have; a failure here must never make the
      // profile look broken.
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;

    if (!_entitled) {
      return _Section(
        title: 'Your form',
        child: Text(
          'Rating history, streaks and your peak are part of a '
          'subscription. Your battles are still being recorded, so it '
          'will all be here waiting.',
          style: text.bodySmall,
        ),
      );
    }

    final summary = _summary;
    // Nothing to show is said plainly rather than rendered as a row of
    // zeroes, which reads as broken rather than as new.
    if (summary == null || (summary['matches'] as num? ?? 0) == 0) {
      return _Section(
        title: 'Your form',
        child: Text(
          'Play a ranked battle and your form starts here.',
          style: text.bodySmall,
        ),
      );
    }

    final net = (summary['netChange'] as num?)?.toInt() ?? 0;
    final form = summary['form'] as String?;
    final streak = (summary['streak'] as Map?)?.cast<String, dynamic>();
    final peak = (summary['peakRating'] as num?)?.toInt();

    return _Section(
      title: 'Your form',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                form == 'climbing'
                    ? Icons.trending_up
                    : form == 'sliding'
                        ? Icons.trending_down
                        : Icons.trending_flat,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  form == 'climbing'
                      ? 'Climbing - up $net over your last '
                          '${summary['windowMatches']}'
                      : form == 'sliding'
                          ? 'Sliding - down ${net.abs()} over your last '
                              '${summary['windowMatches']}'
                          : 'Level over your last ${summary['windowMatches']}',
                  style: text.bodyMedium,
                ),
              ),
            ],
          ),
          if (streak != null) ...[
            const SizedBox(height: 6),
            Text(
              streak['type'] == 'win'
                  ? '${streak['count']} in a row.'
                  : '${streak['count']} losses in a row. It happens.',
              style: text.bodySmall,
            ),
          ],
          if (peak != null) ...[
            const SizedBox(height: 6),
            Text('Peak rating: $peak', style: text.bodySmall),
          ],
          const SizedBox(height: 12),
          // A list rather than a chart: on a phone, ten rows each naming a
          // real result say more than a sparkline a centimetre tall, and
          // the per-match delta is the thing people actually query.
          ..._entries.take(5).map((e) {
            final delta = (e['delta'] as num?)?.toInt() ?? 0;
            final won = e['won'] == true;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      delta >= 0 ? '+$delta' : '$delta',
                      style: text.bodySmall,
                    ),
                  ),
                  Text(won ? 'won' : 'lost', style: text.bodySmall),
                  const Spacer(),
                  Text('${(e['ratingAfter'] as num?)?.toInt() ?? ''}',
                      style: text.bodySmall),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        child,
        const SizedBox(height: 24),
      ],
    );
  }
}
