import 'package:flutter/material.dart';

import '../../core/services/main_stage_service.dart';
import '../../screens/tournament/main_stage_screen.dart';
import '../../theme/app_theme.dart';

/// Home banner that appears ONLY when the viewer is involved in this week's
/// Main Stage finals (finalist / alternate / judge). It's the front door to
/// MainStageScreen - confirm your spot, see the locked field, or make your
/// callout. Renders nothing for everyone else and when no finals are running
/// (the flag is off until launch), so Home stays clean.
class MainStageBanner extends StatelessWidget {
  const MainStageBanner({super.key, this.service});

  final MainStageService? service;

  @override
  Widget build(BuildContext context) {
    final svc = service ?? MainStageService();
    return StreamBuilder<MainStageView?>(
      stream: svc.watch(),
      builder: (context, snap) {
        final v = snap.data;
        if (v == null || v.role == MainStageRole.none) {
          return const SizedBox.shrink();
        }
        final copy = _copy(v);
        if (copy == null) return const SizedBox.shrink();
        final gold = context.palette.reward;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: gold.withValues(alpha: copy.urgent ? 0.18 : 0.10),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MainStageScreen()),
              ),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: gold.withValues(alpha: copy.urgent ? 0.5 : 0.25),
                  ),
                ),
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(copy.icon, color: gold),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            copy.title,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                    fontWeight: FontWeight.w800, color: gold),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            copy.sub,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: gold),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  ({String title, String sub, IconData icon, bool urgent})? _copy(
      MainStageView v) {
    // Live - everyone involved should get to the show.
    if (v.status == 'live') {
      return (
        title: 'The Main Stage is LIVE',
        sub: 'Tap to join the finals.',
        icon: Icons.sensors,
        urgent: true,
      );
    }
    if (v.status == 'locked') {
      if (v.calloutOpen) {
        return (
          title: "You're the #1 seed — make your callout",
          sub: 'Pick who you want in your semifinal.',
          icon: Icons.campaign,
          urgent: true,
        );
      }
      return (
        title: 'The Main Stage field is set',
        sub: 'Tap for the bracket and what happens next.',
        icon: Icons.emoji_events,
        urgent: false,
      );
    }
    // accepting
    final needsAnswer = v.invite == InviteStatus.pending ||
        v.invite == InviteStatus.declined ||
        v.invite == InviteStatus.notInvited;
    switch (v.role) {
      case MainStageRole.finalist:
        return (
          title: needsAnswer
              ? 'You made the Main Stage — confirm'
              : "You're in the Main Stage",
          sub: needsAnswer
              ? 'Confirm by Thursday 4pm or your spot goes to an alternate.'
              : 'Field locks Thursday 4pm.',
          icon: Icons.emoji_events,
          urgent: needsAnswer,
        );
      case MainStageRole.alternate:
        return (
          title: needsAnswer
              ? "You're an alternate — confirm you're around"
              : "You're confirmed as an alternate",
          sub: 'If a finalist drops by Thursday 4pm, you roll in.',
          icon: Icons.event_seat,
          urgent: needsAnswer,
        );
      case MainStageRole.judge:
        return (
          title: needsAnswer
              ? "You're on the judging panel — confirm"
              : "You're judging the finals",
          sub: 'Five judges decide the Main Stage. Confirm by Thursday 4pm.',
          icon: Icons.gavel,
          urgent: needsAnswer,
        );
      case MainStageRole.none:
        return null;
    }
  }
}
