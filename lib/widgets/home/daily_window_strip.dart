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
  const DailyWindowStrip({super.key});

  @override
  State<DailyWindowStrip> createState() => _DailyWindowStripState();
}

class _DailyWindowStripState extends State<DailyWindowStrip> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
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
        final gold = context.palette.reward;
        final liveColor = context.palette.live;
        final accent = live ? liveColor : gold;

        final hours =
            '${_h(config.startHourPacific)}-${_h(config.endHourPacific)} Pacific';
        final String right = live
            ? '${_mins(window.end, now)} left'
            : 'in ${_remaining(window.start, now)}';

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: accent.withValues(alpha: 0.12),
              border: Border.all(color: accent.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(live ? Icons.bolt : Icons.bolt_outlined,
                    size: 18, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: live ? '2X POINTS LIVE' : '2X POINTS',
                          style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                            fontSize: 13,
                          ),
                        ),
                        TextSpan(
                          text: '  ·  $hours',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
            ),
          ),
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
