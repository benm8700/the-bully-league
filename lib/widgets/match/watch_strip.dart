import 'package:flutter/material.dart';

import '../../core/main_stage_battle.dart';
import '../../theme/app_theme.dart';

/// The WATCHER STRIP (2026-11-15, approved mockup "Watchers · rapid rounds
/// strip" in the Battle Screen Show Concepts canvas). A thin 40px bar that
/// sits BETWEEN the two stacked camera tiles on the live viewer, so nothing
/// covers a face. Fed by the host's `ms_state` broadcast, the same state the
/// players render.
///
/// NAMES ARE NOT IN THE STRIP (2026-11-15, developer: a long name got cut
/// off, which isn't fair to the roaster). Each player's full name sits on
/// their own video, beside the strip; the speaker's video and name glow. No
/// arrow either - the glow already says who is talking.
///
/// Rapid rounds (ranked / friend): one turn clock with a mic on the left,
/// the logo in the middle, ROUND n/3 on the right. Purple before it starts,
/// pink live, gold for the last word.
///
/// Main Stage (chess clock): both clocks - the top player's on the left, the
/// bottom player's on the right - the holder's lit pink.
class WatchStrip extends StatelessWidget {
  const WatchStrip({
    super.key,
    required this.state,
    required this.topId,
    this.startsInSeconds,
    this.mainStage = false,
  });

  /// The latest battle state, or null before the battle opens.
  final MainStageBattleState? state;

  /// The player on the TOP tile (player 1).
  final String? topId;

  /// Seconds left in the opening countdown, when known.
  final int? startsInSeconds;
  final bool mainStage;

  static const double height = 40;

  static const _pink = Color(0xFFFF2E7E);
  static const _magenta = Color(0xFFC21FD8);
  static const _gold = Color(0xFFF4C838);
  static const _amber = Color(0xFFE59A1A);
  static const _purple = Color(0xFF7B5CFF);
  static const _deepPurple = Color(0xFF4B2FC2);

  static String fmt(int ms) {
    final s = (ms / 1000).ceil().clamp(0, 5999);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final b = state;
    final live = b != null && b.status != MsStatus.pending;
    Widget left;
    Widget right;
    double? fill;
    Color barColor = _pink;

    if (!live) {
      left = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Pill(
            colors: const [_purple, _deepPurple],
            children: [
              Text(
                startsInSeconds == null ? 'STARTING SOON' : 'STARTS IN',
                style: _kicker(Colors.white),
              ),
              if (startsInSeconds != null) ...[
                const SizedBox(width: 4),
                Text(
                  fmt(startsInSeconds! * 1000),
                  style: _clock(context, Colors.white),
                ),
              ],
            ],
          ),
        ],
      );
      right = b != null && b.config.isRounds
          ? _RoundBox(round: 1, count: b.roundCount)
          : const SizedBox.shrink();
    } else if (b.config.isRounds) {
      final floor = b.floor;
      final over = b.isOver;
      final last = b.isLastTurn && !over;
      final colors = last ? const [_gold, _amber] : const [_pink, _magenta];
      final ink = last ? const Color(0xFF1A1206) : Colors.white;
      final ms = floor == null ? 0 : (b.remaining[floor] ?? 0);
      barColor = last ? _gold : _pink;
      fill = over || b.config.turnMs <= 0
          ? null
          : (ms / b.config.turnMs).clamp(0.0, 1.0);
      left = over
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Pill(
                  colors: const [_purple, _deepPurple],
                  children: [Text('TIME!', style: _kicker(Colors.white))],
                ),
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // A caret pointing at whoever holds the mic: up = the top
                // video, down = the bottom one (developer, 2026-11-18).
                if (floor != null)
                  Icon(
                    floor == topId
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 26,
                    color: colors.first,
                    shadows: [Shadow(color: colors.first, blurRadius: 8)],
                  ),
                _Pill(
                  colors: colors,
                  children: [
                    Icon(Icons.mic, size: 13, color: ink),
                    const SizedBox(width: 2),
                    Text(fmt(ms), style: _clock(context, ink)),
                    if (last) ...[
                      const SizedBox(width: 5),
                      Text('LAST WORD', style: _kicker(ink)),
                    ],
                  ],
                ),
              ],
            );
      right = _RoundBox(
        round: b.round.clamp(1, b.roundCount),
        count: b.roundCount,
      );
    } else {
      // Main Stage chess clock: both clocks, the holder's lit gold.
      final ids = b.players;
      final bottomId = ids.firstWhere((p) => p != topId, orElse: () => ids[1]);
      final topOn = b.floor == topId && !b.isOver;
      final bottomOn = b.floor == bottomId && !b.isOver;
      left = Row(
        mainAxisSize: MainAxisSize.min,
        children: [_ChessClock(ms: b.remaining[topId] ?? 0, on: topOn)],
      );
      right = Row(
        mainAxisSize: MainAxisSize.min,
        children: [_ChessClock(ms: b.remaining[bottomId] ?? 0, on: bottomOn)],
      );
    }

    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: mainStage ? const Color(0xFF110C08) : const Color(0xF50A070E),
          border: Border.symmetric(
            horizontal: BorderSide(
              color: mainStage
                  ? const Color(0xFFF6D66B)
                  : Colors.white.withValues(alpha: 0.10),
            ),
          ),
          boxShadow: mainStage
              ? [BoxShadow(color: _gold.withValues(alpha: 0.4), blurRadius: 20)]
              : null,
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Align(alignment: Alignment.centerLeft, child: left),
                  ),
                  const SizedBox(width: 8),
                  const _Logo(),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: right,
                    ),
                  ),
                ],
              ),
            ),
            if (fill != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 2,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: fill,
                    child: ColoredBox(color: barColor),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static TextStyle _kicker(Color c) => TextStyle(
    color: c,
    fontSize: 9,
    fontWeight: FontWeight.w800,
    letterSpacing: 1,
  );

  static TextStyle _clock(BuildContext context, Color c) => TextStyle(
    color: c,
    fontFamily: context.palette.display,
    fontSize: 17,
    height: 1,
    fontVariations: const [FontVariation('wght', 900)],
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.colors, required this.children});
  final List<Color> colors;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(colors: colors),
        boxShadow: [
          BoxShadow(color: colors.first.withValues(alpha: 0.5), blurRadius: 12),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
    return Flexible(
      child: FittedBox(fit: BoxFit.scaleDown, child: pill),
    );
  }
}

class _ChessClock extends StatelessWidget {
  const _ChessClock({required this.ms, required this.on});
  final int ms;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final ink = on ? Colors.white : Colors.white70;
    final clock = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: on
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: const LinearGradient(
                colors: [WatchStrip._pink, WatchStrip._magenta],
              ),
              boxShadow: [
                BoxShadow(
                  color: WatchStrip._pink.withValues(alpha: 0.5),
                  blurRadius: 12,
                ),
              ],
            )
          : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (on) ...[
            Icon(Icons.mic, size: 13, color: ink),
            const SizedBox(width: 2),
          ],
          Text(WatchStrip.fmt(ms), style: WatchStrip._clock(context, ink)),
        ],
      ),
    );
    return Flexible(
      child: FittedBox(fit: BoxFit.scaleDown, child: clock),
    );
  }
}

class _RoundBox extends StatelessWidget {
  const _RoundBox({required this.round, required this.count});
  final int round;
  final int count;

  @override
  Widget build(BuildContext context) {
    final n = count <= 0 ? 3 : count;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text.rich(
          TextSpan(
            text: 'ROUND ',
            children: [
              TextSpan(
                text: '$round/$n',
                style: TextStyle(
                  color: WatchStrip._gold,
                  fontSize: 13,
                  letterSpacing: 0,
                  fontFamily: context.palette.display,
                  fontVariations: const [FontVariation('wght', 900)],
                ),
              ),
            ],
          ),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 8,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < n; i++)
              Container(
                width: 5,
                height: 5,
                margin: EdgeInsets.only(left: i == 0 ? 0 : 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < round ? WatchStrip._gold : null,
                  border: i < round
                      ? null
                      : Border.all(
                          color: WatchStrip._gold.withValues(alpha: 0.7),
                        ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset('assets/branding/bully_league_crown.png', height: 14),
          const SizedBox(height: 1),
          Image.asset(
            'assets/branding/bully_league_wordmark.png',
            width: 64,
            fit: BoxFit.contain,
            semanticLabel: 'The Bully League',
          ),
        ],
      ),
    );
  }
}

/// What kind of battle this is, for watchers and judges (2026-11-15,
/// developer: "that way the judges know exactly what type of play they are
/// judging"). [mainStageRound] is the match's `mainStageShow.round`.
String battleKindLabel(String? mode, {String? mainStageRound}) {
  if (mainStageRound != null && mainStageRound.isNotEmpty) {
    return 'MAIN STAGE · $mainStageRound';
  }
  return switch (mode) {
    'friend' => 'ROAST A FRIEND',
    'improv' => 'FACE-OFF',
    'tournament' => 'MAIN STAGE',
    _ => 'RANKED',
  };
}

/// The colour that goes with [battleKindLabel], matching the Home doors
/// (2026-11-15, developer: Roast a Friend is the pink-red door, Ranked the
/// purple one). Main Stage is gold; Face-Off teal.
Color battleKindColor(String? mode, {bool mainStage = false}) {
  if (mainStage || mode == 'tournament') return const Color(0xFFF4C838);
  return switch (mode) {
    'friend' => const Color(0xFFFF2E7E),
    'improv' => const Color(0xFF0E7C86),
    _ => const Color(0xFFB64DFF),
  };
}
