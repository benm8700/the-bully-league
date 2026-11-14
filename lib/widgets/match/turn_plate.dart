import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'battle_scorebug.dart';

/// RAPID ROUNDS battle HUD (2026-11-14, developer-approved mockup "Final" in
/// the claude.ai artifact "Battle Screen Show Concepts"). ONE timer, because
/// only one turn clock ever runs and unused time never carries over: a lit
/// plate in the top-left that says who is on the mic, the turn's clock, who
/// you're up against (name over city/state over country) and the round.
///
/// Same timer language as the scorebug: pink = your turn, dark glass = theirs,
/// red = "talk to keep it" (the mic is about to pass), gold = the battle's
/// last word. In the last 3 seconds of a turn the number grows and the plate
/// gets a pulsing white edge ([squeeze]).
enum TurnMood { mine, theirs, warning, lastWord }

class TurnPlate extends StatelessWidget {
  const TurnPlate({
    super.key,
    required this.label,
    required this.clockMs,
    required this.totalMs,
    required this.round,
    required this.roundCount,
    required this.mood,
    this.lines = const [],
    this.squeeze = false,
    this.pulse = 0,
    this.warnFill = 0,
  });

  static const double height = 74;

  /// "YOU · ON THE MIC", "JUDGETESTB · ON THE MIC", "YOU · LAST WORD"...
  final String label;
  final int clockMs;
  final int totalMs;
  final int round;
  final int roundCount;
  final TurnMood mood;

  /// Beside the clock: line 1 bold (the name), then location lines. Empty
  /// lines are dropped by the caller; an empty list hides the block.
  final List<String> lines;

  /// Last 3 seconds of a turn: bigger number, pulsing white edge.
  final bool squeeze;
  final double pulse; // 0..1, drives the squeeze edge

  /// While [TurnMood.warning]: how much of the "passing" window is left (1..0).
  final double warnFill;

  static String fmt(int ms) {
    final s = (ms / 1000).ceil().clamp(0, 5999);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final gold = mood == TurnMood.lastWord;
    final ink = gold ? const Color(0xFF1A1205) : Colors.white;
    final lit = mood != TurnMood.theirs;
    final gradient = switch (mood) {
      TurnMood.mine => const [BattleScorebug.pink, BattleScorebug.magenta],
      TurnMood.warning => const [BattleScorebug.red, BattleScorebug.redDeep],
      TurnMood.lastWord => const [Color(0xFFF6D66B), Color(0xFFD9A21E)],
      TurnMood.theirs => const [Color(0xD80C0812), Color(0xD80C0812)],
    };
    final glow = switch (mood) {
      TurnMood.mine => const Color(0x73FF2E7E),
      TurnMood.warning => const Color(0x8CFF2D3A),
      TurnMood.lastWord => const Color(0x80F4C838),
      TurnMood.theirs => const Color(0x00000000),
    };
    final edge = squeeze
        ? Colors.white.withValues(alpha: 0.45 + 0.55 * pulse)
        : (lit ? Colors.transparent : Colors.white.withValues(alpha: 0.14));
    final fill = mood == TurnMood.warning
        ? warnFill
        : (totalMs <= 0 ? 0.0 : clockMs / totalMs);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradient,
        ),
        border: Border.all(color: edge, width: squeeze ? 2.5 : 1),
        boxShadow: [
          if (lit) BoxShadow(color: glow, blurRadius: 22),
          const BoxShadow(
            color: Color(0x73000000),
            blurRadius: 26,
            offset: Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              children: [
                if (lit)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: 26,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(alpha: gold ? 0.3 : 0.2),
                            Colors.white.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 7, 10, 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.mic_rounded,
                            size: 13,
                            color: ink.withValues(alpha: lit ? 1 : 0.8),
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: ink.withValues(alpha: lit ? 1 : 0.85),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Expanded(child: _body(p.display, ink)),
                    ],
                  ),
                ),
                // The turn's draining bar.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 4,
                  child: ColoredBox(
                    color: lit
                        ? Colors.black.withValues(alpha: 0.25)
                        : Colors.white.withValues(alpha: 0.08),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: fill.clamp(0.0, 1.0),
                        child: ColoredBox(
                          color: lit
                              ? ink
                              : Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _RoundBox(round: round, roundCount: roundCount, dark: gold),
        ],
      ),
    );
  }

  Widget _body(String? display, Color ink) {
    if (mood == TurnMood.warning) {
      return Align(
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'TALK TO KEEP IT',
            style: TextStyle(
              fontFamily: display,
              color: ink,
              fontSize: 26,
              height: 1,
              fontVariations: const [FontVariation('wght', 900)],
            ),
          ),
        ),
      );
    }
    final lineColor = switch (mood) {
      TurnMood.theirs => Colors.white.withValues(alpha: 0.75),
      TurnMood.lastWord => ink,
      _ => Colors.white.withValues(alpha: 0.88),
    };
    final nameColor = mood == TurnMood.theirs ? const Color(0xFFCFC6FF) : ink;
    final clock = Text(
      fmt(clockMs),
      style: TextStyle(
        fontFamily: display,
        color: ink,
        fontSize: squeeze ? 40 : 32,
        height: 1,
        fontVariations: const [FontVariation('wght', 900)],
        fontFeatures: const [FontFeature.tabularFigures()],
        shadows: squeeze
            ? [Shadow(color: ink.withValues(alpha: 0.7), blurRadius: 14)]
            : null,
      ),
    );
    return LayoutBuilder(
      builder: (context, c) => Row(
        children: [
          // The clock keeps its size unless the plate is very narrow, where
          // it shrinks rather than pushing the name off the edge.
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: lines.isEmpty ? c.maxWidth : c.maxWidth * 0.55,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: clock,
            ),
          ),
          if (lines.isNotEmpty) ...[
            const SizedBox(width: 9),
            Container(width: 1, height: 30, color: ink.withValues(alpha: 0.3)),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < lines.length; i++)
                    Text(
                      lines[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: i == 0
                          ? TextStyle(
                              color: nameColor,
                              fontSize: lines.length == 1 ? 12 : 11,
                              height: 1.15,
                              fontWeight: FontWeight.w800,
                            )
                          : TextStyle(
                              color: lineColor,
                              fontSize: 9.5,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                            ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RoundBox extends StatelessWidget {
  const _RoundBox({
    required this.round,
    required this.roundCount,
    required this.dark,
  });
  final int round;
  final int roundCount;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: 58,
      color: dark ? const Color(0xD91A1205) : const Color(0x8C0C0812),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'ROUND',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 8,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.3,
            ),
          ),
          Text(
            '$round/$roundCount',
            style: TextStyle(
              fontFamily: p.display,
              color: BattleScorebug.gold,
              fontSize: 19,
              height: 1.1,
              fontVariations: const [FontVariation('wght', 900)],
            ),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= roundCount; i++)
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i <= round ? BattleScorebug.gold : null,
                    border: i <= round
                        ? null
                        : Border.all(
                            color: BattleScorebug.gold.withValues(alpha: 0.7),
                          ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The handoff moment: "YOUR MIC" (pink) sweeps across the middle of the
/// screen when the mic comes to you, a smaller dark "THEIR MIC" when it
/// leaves. Shown for ~0.7s by the battle screen.
class MicFlash extends StatelessWidget {
  const MicFlash({super.key, required this.mine, this.sub});
  final bool mine;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IgnorePointer(
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutBack,
          builder: (context, t, child) => Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset((1 - t) * -120, 0),
              child: child,
            ),
          ),
          child: Transform.rotate(
            angle: -0.07,
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(vertical: mine ? 18 : 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: mine
                      ? const [
                          Color(0x00FF2E7E),
                          BattleScorebug.pink,
                          BattleScorebug.magenta,
                          Color(0x00C21FD8),
                        ]
                      : const [
                          Color(0x000C0812),
                          Color(0xE60C0812),
                          Color(0xE60C0812),
                          Color(0x000C0812),
                        ],
                  stops: const [0, 0.18, 0.82, 1],
                ),
                boxShadow: mine
                    ? const [
                        BoxShadow(color: Color(0x99FF2E7E), blurRadius: 40),
                      ]
                    : null,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.mic_rounded,
                          color: Colors.white,
                          size: mine ? 34 : 22,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          mine ? 'YOUR MIC' : 'THEIR MIC',
                          style: TextStyle(
                            fontFamily: p.display,
                            color: Colors.white,
                            fontSize: mine ? 50 : 30,
                            letterSpacing: 3,
                            height: 1,
                            fontVariations: const [FontVariation('wght', 900)],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      sub!,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
