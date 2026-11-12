import 'dart:async';

import 'package:flutter/material.dart';

/// "Expires in 47m" for a friend challenge (they stand for an hour, see
/// CHALLENGE_TTL_MS in functions/friendBattle.js). Under 5 minutes it turns
/// red and counts seconds, so the banner vanishing at zero never looks like a
/// bug. Renders nothing when the expiry is unknown or already past.
class ExpiryCountdown extends StatefulWidget {
  const ExpiryCountdown({
    super.key,
    required this.expiresAtMs,
    this.prefix = 'Expires in',
    this.style,
  });

  final Object? expiresAtMs;
  final String prefix;
  final TextStyle? style;

  @override
  State<ExpiryCountdown> createState() => _ExpiryCountdownState();
}

class _ExpiryCountdownState extends State<ExpiryCountdown> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static String label(Duration left) {
    if (left.inMinutes >= 5) {
      final h = left.inHours;
      final m = left.inMinutes % 60;
      return h > 0 ? '${h}h ${m}m' : '${left.inMinutes}m';
    }
    final m = left.inMinutes;
    final s = (left.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.expiresAtMs;
    final ms = raw is num ? raw.toInt() : null;
    if (ms == null) return const SizedBox.shrink();
    final left = DateTime.fromMillisecondsSinceEpoch(
      ms,
    ).difference(DateTime.now());
    if (left.isNegative) return const SizedBox.shrink();
    final urgent = left.inMinutes < 5;
    final base = widget.style ?? Theme.of(context).textTheme.bodySmall;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.timer_outlined,
          size: 14,
          color: urgent ? Colors.redAccent : base?.color,
        ),
        const SizedBox(width: 4),
        Text(
          '${widget.prefix} ${label(left)}',
          style: base?.copyWith(
            color: urgent ? Colors.redAccent : null,
            fontWeight: urgent ? FontWeight.w700 : null,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
