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
    // Live - the copy tracks where the viewer stands so it never invites them
    // back into a battle they've already played (the stale-banner bug).
    if (v.status == 'live') {
      switch (v.liveStage) {
        case MainStageLiveStage.playNow:
          return (
            title: "You're up on the Main Stage",
            sub: v.myMatchupIsFinal
                ? 'Tap to play the final.'
                : 'Tap to play your match.',
            icon: Icons.mic,
            urgent: true,
          );
        case MainStageLiveStage.awaitingVerdict:
          return (
            title: 'The judges are deciding',
            sub: 'Tap for the verdict of your battle.',
            icon: Icons.gavel,
            urgent: false,
          );
        case MainStageLiveStage.advancedWaiting:
          return (
            title: 'You advanced!',
            sub: 'Tap to watch while your next battle is set up.',
            icon: Icons.emoji_events,
            urgent: true,
          );
        case MainStageLiveStage.champion:
          return (
            title: 'You won the Main Stage! 🏆',
            sub: 'Tap to see it.',
            icon: Icons.emoji_events,
            urgent: true,
          );
        case MainStageLiveStage.eliminated:
          return (
            title: 'The Main Stage is LIVE',
            sub: 'Tap to watch who takes the crown.',
            icon: Icons.sensors,
            urgent: false,
          );
        case MainStageLiveStage.spectate:
          return (
            title: 'The Main Stage is LIVE',
            sub: 'Tap to join the finals.',
            icon: Icons.sensors,
            urgent: true,
          );
      }
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
              ? 'Congratulations! You made the Main Stage'
              : "Congratulations! You're in the Main Stage",
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
        // A volunteer judge (notInvited) autofills the panel at the 4pm lock -
        // nothing to confirm, so it is never urgent and never says "confirm".
        // Only a hand-picked, invited judge confirms.
        if (v.invite == InviteStatus.notInvited) {
          return (
            title: "You're in the judge pool",
            sub: 'The panel fills from the volunteer pool at the Thursday 4pm '
                'lock — no action needed.',
            icon: Icons.gavel,
            urgent: false,
          );
        }
        final judgeConfirm = v.invite == InviteStatus.pending ||
            v.invite == InviteStatus.declined;
        return (
          title: judgeConfirm
              ? "Congratulations! You're invited to judge"
              : "Congratulations! You're judging the finals",
          sub: judgeConfirm
              ? 'Five judges decide the Main Stage. Confirm by Thursday 4pm.'
              : 'Five judges decide the Main Stage. See you Thursday.',
          icon: Icons.gavel,
          urgent: judgeConfirm,
        );
      case MainStageRole.none:
        return null;
    }
  }
}
