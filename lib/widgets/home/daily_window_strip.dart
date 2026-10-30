import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/services/event_window.dart';
import '../../theme/app_theme.dart';

/// A slim "power hour" strip for the daily 6-7pm window (2x points) - the
/// everyday peak-hour liquidity nudge, separate from the weekly Main Stage card.
///
/// Reads config/eventWindow live; renders NOTHING when the window is disabled or
/// unreadable, so a switched-off promo never makes Home look wrong. Ticks once a
/// minute for the countdown (plenty for a minutes-granularity display).
class DailyWindowStrip extends StatefulWidget {
  const DailyWindowStrip({super.key, this.compact = false});

  /// When true, render a tiny inline line ("⚡ 2X POINTS · in 18h 5m") with no
  /// container - for dropping inside the Play box instead of a full banner. The
  /// name and the 6-7pm hours are dropped; only the draw + countdown remain.
  final bool compact;

  @override
  State<DailyWindowStrip> createState() => _DailyWindowStripState();
}

class _DailyWindowStripState extends State<DailyWindowStrip>
    with SingleTickerProviderStateMixin {
  Timer? _ticker;
  // Drives the pulsing glow while the window is LIVE, so 6-7pm actively grabs
  // attention. Runs continuously but is only read (via AnimatedBuilder) during
  // the live state, so the quiet countdown never repaints per frame.
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('config')
          .doc('eventWindow')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const SizedBox.shrink();
        final config = EventWindowConfig.fromMap(snapshot.data?.data());
        if (!config.enabled) return const SizedBox.shrink();

        final now = DateTime.now().toUtc();
        final window = currentOrNextWindow(now, config);
        final live = window.contains(now);
        // Basement colours (the brand pink), NOT the tournament gold: the 2x
        // multiplier is for everyday Basement play, so it reads in the same
        // family as the Basement hero rather than the gold Main Stage.
        final accent = context.palette.accent;

        // Compact inline line for inside the Play box: just the draw + how long.
        if (widget.compact) {
          final tail = live
              ? 'LIVE  ${_mins(window.end, now)} left'
              : 'in ${_remaining(window.start, now)}';
          return Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.bolt, size: 13, color: accent),
                const SizedBox(width: 3),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '2X POINTS',
                          style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.2,
                            fontSize: 11.5,
                          ),
                        ),
                        TextSpan(
                          text: '  $tail',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.72),
                            fontWeight: FontWeight.w600,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
          );
        }

        final hours =
            '${_h(config.startHourPacific)} to ${_h(config.endHourPacific)}';
        final String right = live
            ? '${_mins(window.end, now)} left'
            : 'in ${_remaining(window.start, now)}';

        final content = Row(
          children: [
            Icon(live ? Icons.bolt : Icons.bolt_outlined,
                size: 18, color: accent),
            const SizedBox(width: 8),
            // One line, with the DRAW first: "2X POINTS - Happy Hour - 6pm to
            // 7pm". 2x points leads (the value), the named window gives
            // context, then the hours; if the strip is too narrow it clips the
            // trailing hours, never the draw.
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: live ? '2X POINTS LIVE' : '2X POINTS',
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.3,
                          fontSize: 13,
                        ),
                      ),
                      TextSpan(
                        text: live
                            ? ' - ${config.name}'
                            : ' - ${config.name} - $hours',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              right,
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ],
        );

        // LIVE pops - a brighter fill, a bold border and a pulsing glow - so the
        // one hour it's on actively pulls people in. Outside the window it's the
        // quiet static countdown.
        Widget strip(double t) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: EdgeInsets.symmetric(
                    horizontal: 12, vertical: live ? 10 : 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: accent.withValues(alpha: live ? 0.22 : 0.12),
                  border: Border.all(
                    color: accent.withValues(alpha: live ? 0.95 : 0.5),
                    width: live ? 1.6 : 1,
                  ),
                  boxShadow: live
                      ? [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.30 + 0.30 * t),
                            blurRadius: 14 + 10 * t,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: content,
              ),
            );

        if (!live) return strip(0);
        return AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) =>
              strip(Curves.easeInOut.transform(_pulse.value)),
        );
      },
    );
  }

  String _h(int hour24) {
    final h = hour24 % 12 == 0 ? 12 : hour24 % 12;
    return '$h${hour24 < 12 ? 'am' : 'pm'}';
  }

  String _mins(DateTime end, DateTime now) {
    final m = end.difference(now).inMinutes;
    return '${m < 1 ? 1 : m}m';
  }

  String _remaining(DateTime target, DateTime now) {
    final d = target.difference(now);
    if (d.isNegative) return '0m';
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    return hours >= 1 ? '${hours}h ${minutes}m' : '${d.inMinutes}m';
  }
}
