import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../screens/tournament/tournament_hub_screen.dart';
import 'home_action_card.dart';

/// The Main Stage hero card on Home - the permanent front door to the WEEKLY
/// tournament hub.
///
/// A neon gold capsule (crown, "MAIN STAGE", a COMING SOON badge while it's off,
/// whole-card tap to the hub), matched in size to the Play/Watch pills. The hub
/// itself explains the format, so there's no "?" on the card.
///
/// It is NOT tied to the daily 6-7pm window any more: the weekly Main Stage is
/// its own thing, the countdown to Thursday's finals lives in the hub, and the
/// daily "power hour" has its own slim strip (DailyWindowStrip). Always shown -
/// the hub handles its own empty states before the tournament is switched on.
class MainStageCard extends StatelessWidget {
  const MainStageCard({super.key});

  @override
  Widget build(BuildContext context) {
    void openHub() => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TournamentHubScreen()),
        );

    // Watches the tournament flag so a "COMING SOON" badge shows while it is
    // switched off (which it is now). Everything underneath - the card, the
    // hub, all the features - stays fully intact and tappable; this is only a
    // reminder to users that the monthly Main Stage is not live yet, and it
    // disappears automatically the moment config/tournament.enabled flips true.
    //
    // Same slim side margin as the Play/Watch cards so all three line up.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('config')
          .doc('tournament')
          .snapshots(),
      builder: (context, snap) {
        final enabled = snap.data?.data()?['enabled'] == true;
        // Same shared neon card as Play/Watch, so all three are identical in
        // size. A COMING SOON badge rides under the label while the tournament
        // is switched off; it clears the moment config/tournament.enabled flips.
        return HomeActionCard(
          label: 'MAIN STAGE',
          icon: HomeActionCard.neonIcon(Icons.emoji_events, _kGold), // trophy
          accent: _kGold,
          accentEnd: _kGoldDeep,
          onTap: openHub,
          badge: enabled ? null : _comingSoonBadge(),
        );
      },
      ),
    );
  }

  /// A small gold-rimmed COMING SOON pill under the label while the tournament
  /// is switched off.
  Widget _comingSoonBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _kGold.withValues(alpha: 0.8), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 12, color: _kGold),
          const SizedBox(width: 5),
          Text(
            'COMING SOON',
            style: TextStyle(
              color: _kGold,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

}

/// The neon gold for the Main Stage pill (gold -> deep gold gradient border).
const Color _kGold = Color(0xFFF8C73B);
const Color _kGoldDeep = Color(0xFFE0890F);
