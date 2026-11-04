import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../core/services/judge_seat_service.dart';
import '../../theme/app_theme.dart';

/// The PAID panel-seat card for the Judges tab - the "panel seats" sink from
/// the locked economy model, offered beside the free volunteer route.
///
/// Self-gating: renders NOTHING unless the seat flag is on (both
/// config/tournament.enabled and judgeSeatsEnabled), so the Judges tab reads
/// exactly as before while it's off - the seat is never offered before it can
/// be bought. A fixed price, a minority of the panel, first-come.
class JudgeSeatCard extends StatefulWidget {
  const JudgeSeatCard({super.key});

  @override
  State<JudgeSeatCard> createState() => _JudgeSeatCardState();
}

class _JudgeSeatCardState extends State<JudgeSeatCard> {
  final _service = JudgeSeatService();
  JudgeSeatState? _state;
  bool _buying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await _service.state();
    if (mounted) setState(() => _state = s);
  }

  Future<void> _buy() async {
    final s = _state;
    if (s == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Buy a seat on the panel?'),
        content: Text(
          'Spend ${s.price} points to judge this week\'s Main Stage, live on '
          'camera. Bought seats are a minority of the panel — the rest are '
          'earned. If you end up qualifying as a finalist, you can\'t judge '
          'your own tournament, so your points come back.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Buy seat')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _buying = true);
    try {
      await _service.buy();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Seat booked — you\'re on this week\'s panel.')));
      await _load();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Could not buy a seat.')));
      await _load();
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    if (s == null || !s.enabled) return const SizedBox.shrink();
    final gold = context.palette.reward;
    final text = Theme.of(context).textTheme;

    final held = s.youHold;
    final affordable = s.balance >= s.price;

    // The trailing control / status.
    Widget trailing;
    if (held) {
      trailing = Icon(Icons.check_circle, color: gold, size: 22);
    } else if (s.soldOut) {
      trailing = Text('Sold out',
          style: text.labelMedium
              ?.copyWith(color: Colors.white.withValues(alpha: 0.6)));
    } else if (!s.eligible) {
      trailing = const SizedBox.shrink();
    } else if (!affordable) {
      trailing = Text('${s.price - s.balance} more',
          style: text.labelMedium
              ?.copyWith(color: Colors.white.withValues(alpha: 0.6)));
    } else if (_buying) {
      trailing = const SizedBox(
          width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    } else {
      trailing = FilledButton(
        onPressed: _buy,
        style: FilledButton.styleFrom(
            backgroundColor: gold, foregroundColor: const Color(0xFF3D2C00)),
        child: const Text('Buy seat'),
      );
    }

    // The sub-line.
    final String sub;
    if (held) {
      sub = "You've got a seat on this week's panel.";
    } else if (s.soldOut) {
      sub = 'The bought seats are gone for this week.';
    } else if (!s.eligible) {
      sub = s.message ?? 'You can\'t buy a seat yet.';
    } else {
      final left = s.seatsRemaining == 1
          ? 'Last seat'
          : '${s.seatsRemaining} of ${s.seatsTotal} seats left';
      sub = '$left · ${s.price} pts · skip the climb and judge this week.';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.black.withValues(alpha: 0.35),
        border: Border.all(
            color: held
                ? gold.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Text('🎟️', style: text.titleLarge),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(held ? 'Your panel seat' : 'Buy a seat on the panel',
                    style: text.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800, color: gold)),
                const SizedBox(height: 2),
                Text(sub,
                    style: text.bodySmall
                        ?.copyWith(color: Colors.white.withValues(alpha: 0.7))),
              ],
            ),
          ),
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    );
  }
}
