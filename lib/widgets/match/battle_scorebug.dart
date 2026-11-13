import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The "Fight Night" scorebug (2026-11-12, developer: "this needs to be a
/// show"). One broadcast bar across the top of a battle: your plate on the
/// left, theirs on the right, VS + LIVE between. Part of ONE timer language
/// shared by every countdown in a battle - a lit plate with a big display
/// number and a bar that drains, where only the colour says the moment:
///
///   pink   = you hold the mic          (live)
///   red    = dead-air warning          ("PASSING IN 3", same plate)
///   gold   = your last turn            (opponent is out of time)
///   dim    = waiting / not on the mic
///
/// Mockups: claude.ai artifact "Battle Screen Show Concepts", concept A.
enum PlateMood { idle, live, warning, finalWord }

class BattleScorebug extends StatelessWidget {
  const BattleScorebug({
    super.key,
    required this.oppName,
    required this.myMs,
    required this.oppMs,
    required this.totalMs,
    required this.myMood,
    required this.oppLive,
    this.warningValue,
    this.mySteals = 0,
    this.oppSteals = 0,
    this.totalSteals = 0,
    this.flashMine = 0,
    this.flashOpp = 0,
  });

  final String oppName;
  final int myMs;
  final int oppMs;

  /// A full clock, for the draining bars.
  final int totalMs;
  final PlateMood myMood;

  /// Whether the opponent holds the mic (their plate lights up).
  final bool oppLive;

  /// The big line while [PlateMood.warning] ("PASSING IN 3", or "ENDING IN
  /// 3" on the last turn).
  final String? warningValue;
  final int mySteals;
  final int oppSteals;
  final int totalSteals;

  /// 0..1 red flash while an interrupt winds up against that player.
  final double flashMine;
  final double flashOpp;

  static const pink = Color(0xFFFF2E7E);
  static const magenta = Color(0xFFC21FD8);
  static const red = Color(0xFFFF2D3A);
  static const redDeep = Color(0xFFB3122A);
  static const gold = Color(0xFFF4C838);

  static String fmt(int ms) {
    final s = (ms / 1000).ceil();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 78,
      decoration: BoxDecoration(
        color: const Color(0xD10C0812),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x80000000),
            blurRadius: 30,
            offset: Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _Plate(
              label: switch (myMood) {
                PlateMood.live => 'YOU · ON THE MIC',
                PlateMood.warning => 'OUT OF MATERIAL?',
                PlateMood.finalWord => 'FINAL WORD',
                PlateMood.idle => 'YOU',
              },
              value: myMood == PlateMood.warning && warningValue != null
                  ? warningValue!
                  : fmt(myMs),
              fill: totalMs <= 0 ? 0 : myMs / totalMs,
              mood: myMood,
              alignEnd: false,
              steals: mySteals,
              totalSteals: totalSteals,
              flash: flashMine,
            ),
          ),
          _Middle(),
          Expanded(
            child: _Plate(
              label: oppName.toUpperCase(),
              value: fmt(oppMs),
              fill: totalMs <= 0 ? 0 : oppMs / totalMs,
              mood: oppLive ? PlateMood.live : PlateMood.idle,
              alignEnd: true,
              steals: oppSteals,
              totalSteals: totalSteals,
              flash: flashOpp,
            ),
          ),
        ],
      ),
    );
  }
}

class _Middle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: 50,
      color: const Color(0xFF0C0812),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'VS',
            style: TextStyle(
              fontFamily: p.display,
              color: BattleScorebug.gold,
              fontSize: 15,
              fontVariations: const [FontVariation('wght', 900)],
            ),
          ),
          const SizedBox(height: 4),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _LiveDot(),
              SizedBox(width: 3),
              Text(
                'LIVE',
                style: TextStyle(
                  color: BattleScorebug.pink,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A softly pulsing red-pink dot: the "we're on air" light.
class _LiveDot extends StatefulWidget {
  const _LiveDot();
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: BattleScorebug.pink,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: BattleScorebug.pink, blurRadius: 6)],
        ),
      ),
    );
  }
}

class _Plate extends StatelessWidget {
  const _Plate({
    required this.label,
    required this.value,
    required this.fill,
    required this.mood,
    required this.alignEnd,
    required this.steals,
    required this.totalSteals,
    required this.flash,
  });

  final String label;
  final String value;
  final double fill;
  final PlateMood mood;
  final bool alignEnd;
  final int steals;
  final int totalSteals;
  final double flash;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final lit = mood != PlateMood.idle;
    final onGold = mood == PlateMood.finalWord;
    final ink = onGold ? const Color(0xFF1A1205) : Colors.white;
    final gradient = switch (mood) {
      PlateMood.live => const [BattleScorebug.pink, BattleScorebug.magenta],
      PlateMood.warning => const [BattleScorebug.red, BattleScorebug.redDeep],
      PlateMood.finalWord => const [Color(0xFFF6D66B), Color(0xFFD9A21E)],
      PlateMood.idle => const [Color(0x00000000), Color(0x00000000)],
    };
    final cross = alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradient,
        ),
        border: flash > 0
            ? Border.all(
                color: Color.lerp(
                  Colors.transparent,
                  BattleScorebug.red,
                  0.4 + 0.6 * flash,
                )!,
                width: 2.5,
              )
            : null,
      ),
      child: Stack(
        children: [
          if (lit)
            // Gloss along the top edge - the lit-plate "glass" cue.
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
                      Colors.white.withValues(alpha: onGold ? 0.30 : 0.22),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: cross,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (mood == PlateMood.live ||
                          mood == PlateMood.warning) ...[
                        Icon(Icons.mic_rounded, size: 13, color: ink),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          color: lit
                              ? ink
                              : Colors.white.withValues(alpha: 0.7),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                        ),
                      ),
                      // Interrupt pips beside the name (only when
                      // interrupts are in play), so the plate stays 78 tall.
                      if (totalSteals > 0) ...[
                        const SizedBox(width: 5),
                        Text(
                          '${'●' * steals}${'○' * (totalSteals - steals).clamp(0, 99)}',
                          style: TextStyle(
                            color: lit
                                ? ink.withValues(alpha: 0.8)
                                : Colors.white54,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontFamily: p.display,
                      color: lit ? ink : Colors.white.withValues(alpha: 0.78),
                      fontSize: 32,
                      height: 1,
                      fontVariations: const [FontVariation('wght', 900)],
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // The draining bar along the bottom edge.
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
                alignment: alignEnd
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: fill.clamp(0.0, 1.0),
                  child: ColoredBox(
                    color: lit ? ink : Colors.white.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The warm-up countdown as a ring (the timer language's "waiting" form):
/// a purple ring drains around the big number.
class WarmupRing extends StatelessWidget {
  const WarmupRing({super.key, required this.seconds, required this.total});

  final int seconds;
  final int total;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      width: 168,
      height: 168,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: total <= 0 ? 0 : seconds / total),
        duration: const Duration(milliseconds: 950),
        builder: (context, v, _) => CustomPaint(
          painter: _RingPainter(v),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$seconds',
                  style: TextStyle(
                    fontFamily: p.display,
                    color: Colors.white,
                    fontSize: 68,
                    height: 1,
                    fontVariations: const [FontVariation('wght', 900)],
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'GET READY',
                  style: TextStyle(
                    color: Color(0xFFCFC6FF),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fill);
  final double fill;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 8;
    canvas.drawCircle(
      c,
      r + 6,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF6D4AFF).withValues(alpha: 0.35),
            const Color(0x006D4AFF),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r + 6)),
    );
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..color = const Color(0x40A99BFF);
    canvas.drawCircle(c, r, track);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(
        colors: [Color(0xFFA99BFF), Color(0xFF6D4AFF), Color(0xFFA99BFF)],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -1.5708,
      6.2832 * fill.clamp(0.0, 1.0),
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fill != fill;
}

/// The end-of-battle stamp ("TIME!" / "DEAD AIR") that slams in before the
/// verdict screen.
class EndStamp extends StatelessWidget {
  const EndStamp({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 2.2, end: 1.0),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutBack,
      builder: (context, s, child) => Transform.scale(
        scale: s,
        child: Opacity(opacity: (2.2 - s).clamp(0.0, 1.0), child: child),
      ),
      child: Transform.rotate(
        angle: -0.1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            border: Border.all(color: Colors.white, width: 4),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.35),
                blurRadius: 30,
              ),
            ],
          ),
          child: Text(
            text,
            style: TextStyle(
              fontFamily: p.display,
              color: Colors.white,
              fontSize: 48,
              letterSpacing: 3,
              height: 1,
              fontVariations: const [FontVariation('wght', 900)],
            ),
          ),
        ),
      ),
    );
  }
}
