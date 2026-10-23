import 'package:flutter/material.dart';

import '../core/services/main_stage_service.dart';
import '../screens/tournament/judges_room_screen.dart';
import '../screens/tournament/main_stage_screen.dart';
import '../theme/app_theme.dart';

/// A loud, app-wide alert that pulls the KEY people into the Main Stage no
/// matter which tab they're on - the in-app half of the "carry them to the
/// stage" push (the push covers a closed/backgrounded app; this covers an open
/// one). Mounted in MainShell above the tabs, so it rides over every tab.
///
/// It only appears for someone with IMMINENT action:
///   - a finalist whose battle is up (playNow) - "step on stage",
///   - a judge while a battle is on stage - "cast your verdict".
/// Everyone else (waiting finalists, the crowd, between battles) sees nothing,
/// so it never nags. Tapping opens the Main Stage, which routes to the right
/// sub-state (play / judges' room).
class MainStageAlertBar extends StatefulWidget {
  const MainStageAlertBar({super.key});

  @override
  State<MainStageAlertBar> createState() => _MainStageAlertBarState();
}

class _MainStageAlertBarState extends State<MainStageAlertBar> {
  final _service = MainStageService();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MainStageView?>(
      stream: _service.watch(),
      builder: (context, snap) {
        final v = snap.data;
        final cue = v == null ? null : _cue(v);
        if (cue == null) return const SizedBox.shrink();
        final bg = context.palette.live;
        return Material(
          color: bg,
          child: InkWell(
            // The judge's "needs your verdict" cue drops STRAIGHT into the
            // panel for that battle - one tap, no intermediate Main Stage
            // screen. Every other cue routes through the Main Stage, which
            // then picks the right sub-state.
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => cue.judgeMatchId != null
                    ? JudgesRoomScreen(matchId: cue.judgeMatchId!)
                    : const MainStageScreen(),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(cue.icon, color: Colors.white, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        cue.text,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _pill(cue.action),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  ({String text, String action, IconData icon, String? judgeMatchId})? _cue(
      MainStageView v) {
    if (v.status != 'live') return null;
    if (v.liveStage == MainStageLiveStage.playNow) {
      return (
        text: v.myMatchupIsFinal
            ? "You're in the FINAL - it's your turn on stage"
            : "You're up on the Main Stage",
        action: v.myMatchupIsFinal ? 'Play final' : 'Play',
        icon: Icons.mic,
        judgeMatchId: null,
      );
    }
    if (v.role == MainStageRole.judge && v.liveBattleMatchId != null) {
      return (
        text: 'A Main Stage battle needs your verdict',
        action: 'Judge',
        icon: Icons.gavel,
        // Carry the match id so the tap opens the judges' room directly.
        judgeMatchId: v.liveBattleMatchId,
      );
    }
    // Just battled: pull them to WATCH the panel decide it, rather than leaving
    // them idle. The whole point of the show is watching the judges judge.
    if (v.liveStage == MainStageLiveStage.awaitingVerdict) {
      return (
        text: 'Your battle is being judged — watch the panel',
        action: 'Watch',
        icon: Icons.gavel,
        judgeMatchId: null,
      );
    }
    return null;
  }

  Widget _pill(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: context.palette.live,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      );
}
