import 'package:flutter/material.dart';

import '../core/services/belt_service.dart';

/// A compact "🏆 Reigning Champion" pill, shown on a profile only when THAT
/// player currently holds The Belt (the Daily Gauntlet title). Renders nothing
/// otherwise, so it is safe to drop into any profile header. Live, so it
/// appears/vanishes the moment the belt changes hands.
class BeltFlair extends StatelessWidget {
  const BeltFlair({super.key, required this.uid});

  /// The profile owner's uid - the pill shows only if this uid holds the belt.
  final String uid;

  static const _gold = Color(0xFFF4C838);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BeltHolder>(
      stream: BeltService.watch(),
      builder: (context, snap) {
        final belt = snap.data;
        if (belt == null || belt.holderUid != uid) {
          return const SizedBox.shrink();
        }
        final defended = belt.defenseCount > 0;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: const LinearGradient(
              colors: [Color(0xFF3A2F14), Color(0xFF1A1508)],
            ),
            border: Border.all(color: _gold.withValues(alpha: 0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🏆', style: TextStyle(fontSize: 15)),
              const SizedBox(width: 6),
              Text(
                defended
                    ? 'Reigning Champion · ×${belt.defenseCount}'
                    : 'Reigning Champion',
                style: const TextStyle(
                  color: _gold,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
