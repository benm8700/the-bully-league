import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/services/event_window.dart';
import '../../screens/tournament/tournament_hub_screen.dart';
import '../../theme/app_theme.dart';
import 'home_action_card.dart';

/// Where the weekly show stands right now, from the clock alone.
enum ShowPhase {
  /// Any normal day - the compact card sits below the three doors.
  week,

  /// Show day, before 6pm Pacific - the big card moves to the top of Home.
  showDay,

  /// 6-9pm Pacific on show night - big card, LIVE NOW.
  live,
}

/// How long after the 6pm start the card keeps saying LIVE.
const Duration kShowLength = Duration(hours: 3);

/// How far ahead of the show the big card takes the top of Home.
const Duration kShowDayLead = Duration(hours: 12);

/// Pure, so it can be tested: the phase at [now] given the NEXT show start.
ShowPhase showPhaseAt(DateTime now, DateTime nextShow) {
  final previous = nextShow.subtract(const Duration(days: 7));
  if (!now.isBefore(previous) && now.isBefore(previous.add(kShowLength))) {
    return ShowPhase.live;
  }
  if (nextShow.difference(now) <= kShowDayLead) return ShowPhase.showDay;
  return ShowPhase.week;
}

/// The Main Stage card on Home (2026-11-10 redesign, developer's call).
///
/// Most of the week it is a COMPACT gold marquee below the three doors:
/// chasing bulbs, a shine sweep, foil "MAIN STAGE", "Win the Belt" and a
/// countdown to Thursday 6pm Pacific - the shiniest thing on Home without
/// pushing the XP/rewards/streak rows off the first screen. On show day it
/// moves ABOVE the doors at full size with a to-the-second countdown, and on
/// show night it turns LIVE. While config/tournament.enabled is false it stays
/// compact and says CLOSED.
///
/// Use [MainStageHomeSlot.top] above the doors and [MainStageHomeSlot.bottom]
/// below them: exactly one of the two renders at any time.
class MainStageHomeSlot extends StatefulWidget {
  const MainStageHomeSlot.top({super.key}) : top = true;
  const MainStageHomeSlot.bottom({super.key}) : top = false;

  final bool top;

  @override
  State<MainStageHomeSlot> createState() => _MainStageHomeSlotState();
}

class _MainStageHomeSlotState extends State<MainStageHomeSlot> {
  Timer? _clock;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('config')
          .doc('tournament')
          .snapshots(),
      builder: (context, snap) {
        final enabled = snap.data?.data()?['enabled'] == true;
        // MAIN STAGE SPONSOR (2026-11-11, developer's call): "presented by
        // ___" appears once config/tournament.sponsorName is set. Empty =
        // nothing shown.
        final sponsorRaw = snap.data?.data()?['sponsorName'];
        final sponsor = sponsorRaw is String && sponsorRaw.trim().isNotEmpty
            ? sponsorRaw.trim()
            : null;
        final next = nextMainStageFinals(_now);
        final phase = enabled ? showPhaseAt(_now, next) : ShowPhase.week;
        final big = phase != ShowPhase.week;
        if (big != widget.top) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, widget.top ? 14 : 0),
          child: MainStageMarquee(
            enabled: enabled,
            phase: phase,
            untilShow: next.difference(_now),
            sponsor: enabled ? sponsor : null,
          ),
        );
      },
    );
  }
}

class MainStageMarquee extends StatefulWidget {
  const MainStageMarquee({
    super.key,
    required this.enabled,
    required this.phase,
    required this.untilShow,
    this.sponsor,
  });

  final bool enabled;
  final ShowPhase phase;
  final Duration untilShow;

  /// "presented by ___" (config/tournament.sponsorName), or null.
  final String? sponsor;

  @override
  State<MainStageMarquee> createState() => _MainStageMarqueeState();
}

const Color _gold = Color(0xFFF4C838);
const Color _goldDeep = Color(0xFFA8740A);
const Color _goldPale = Color(0xFFFFF3C4);
const Color _liveRed = Color(0xFFFF3345);

class _MainStageMarqueeState extends State<MainStageMarquee>
    with TickerProviderStateMixin {
  late final AnimationController _chase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final AnimationController _shine = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  );

  @override
  void initState() {
    super.initState();
    _syncMotion();
  }

  @override
  void didUpdateWidget(MainStageMarquee old) {
    super.didUpdateWidget(old);
    if (old.enabled != widget.enabled || old.phase != widget.phase) {
      _syncMotion();
    }
  }

  /// CLOSED (2026-11-11, developer's call - "a room that's closed", the
  /// comedy-club version of COMING SOON). The room is closed while the switch
  /// is off AND all week while it's on, until show day. Closed = gray, no
  /// chase, no shine.
  bool get _closed => !widget.enabled || widget.phase == ShowPhase.week;

  void _syncMotion() {
    if (!_closed) {
      if (!_chase.isAnimating) _chase.repeat();
      if (!_shine.isAnimating) _shine.repeat();
    } else {
      _chase
        ..stop()
        ..value = 0;
      _shine
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _chase.dispose();
    _shine.dispose();
    super.dispose();
  }

  bool get _big => widget.phase != ShowPhase.week;
  bool get _live => widget.phase == ShowPhase.live;

  void _onTap() {
    if (widget.enabled) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const TournamentHubScreen()));
    } else {
      showModeInfo(
        context,
        title: 'Main Stage',
        body:
            'The weekly championship. The top roasters earn their spot and '
            'battle live for the title and the belt, every Thursday night. '
            'The room is closed for now.',
        accent: _gold,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = _big ? 210.0 : 92.0;
    final edge = _live ? _liveRed : _gold;
    final card = _card(height, edge);
    if (!_closed) return card;
    // CLOSED: the whole card in grayscale and a little dimmed - you can
    // still read it ("oh, Main Stage, cool") but it doesn't gleam yet.
    final gray = Opacity(
      opacity: 0.8,
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]),
        child: card,
      ),
    );
    // A tilted CLOSED stamp across the MAIN STAGE title (2026-11-11,
    // developer: the pill on the right looked off). Outside the grayscale so
    // it reads crisp.
    return Stack(
      children: [
        gray,
        // Sits over the END of the title only, so "Win the Belt" stays
        // readable underneath.
        Positioned(
          right: _big ? 28 : 34,
          top: _big ? 56 : 14,
          child: IgnorePointer(
            child: Transform.rotate(
              angle: -0.1,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Text(
                  'CLOSED',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(double height, Color edge) {
    return Semantics(
      button: true,
      label: _live
          ? 'Main Stage is live now'
          : 'Main Stage, weekly championship. Win the Belt.',
      child: GestureDetector(
        onTap: _onTap,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _gold, width: 2),
            gradient: RadialGradient(
              center: const Alignment(0, -1.2),
              radius: 1.4,
              colors: _live
                  ? const [
                      Color(0xFF5A1010),
                      Color(0xFF240707),
                      Color(0xFF0E0505),
                    ]
                  : const [
                      Color(0xFF4A2A05),
                      Color(0xFF1D1004),
                      Color(0xFF0E0904),
                    ],
              stops: const [0, 0.55, 1],
            ),
            boxShadow: [
              BoxShadow(color: edge.withValues(alpha: 0.45), blurRadius: 24),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _BulbPainter(_chase, spacing: _big ? 17 : 15),
                  ),
                ),
                RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _shine,
                    builder: (context, _) =>
                        CustomPaint(painter: _ShinePainter(_shine.value)),
                  ),
                ),
                Padding(
                  padding: _big
                      ? const EdgeInsets.fromLTRB(22, 18, 22, 18)
                      : const EdgeInsets.symmetric(horizontal: 18),
                  child: _big ? _bigContent(context) : _compactContent(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _foil(BuildContext context, String text, double size) {
    final p = context.palette;
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (r) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_goldPale, _gold, _goldDeep, Color(0xFFFFE08A)],
        stops: [0, 0.42, 0.58, 1],
      ).createShader(r),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: p.display,
          fontSize: size,
          height: 1,
          letterSpacing: 1,
          fontVariations: [
            const FontVariation('wght', 900),
            FontVariation('wdth', p.displayWidth),
          ],
        ),
      ),
    );
  }

  Widget _compactContent(BuildContext context) {
    final d = widget.untilShow;
    final countdown = d.inDays > 0
        ? '${d.inDays}d ${d.inHours % 24}h'
        : '${d.inHours}h ${d.inMinutes % 60}m';
    return Row(
      children: [
        const Icon(
          Icons.emoji_events_rounded,
          color: _gold,
          size: 30,
          shadows: [Shadow(color: _gold, blurRadius: 12)],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: _foil(context, 'MAIN STAGE', 25),
              ),
              const SizedBox(height: 4),
              // Shrinks rather than cutting off the show time when the
              // SHOWTIME countdown pill takes room on show week.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.sponsor != null
                      ? 'Win the Belt · presented by ${widget.sponsor}'
                      : 'Win the Belt · Thursdays 6PM PT',
                  maxLines: 1,
                  softWrap: false,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        // CLOSED is a stamp across the title instead (see build).
        if (!_closed) _pill(top: 'SHOWTIME IN', main: countdown),
      ],
    );
  }

  Widget _pill({String? top, required String main}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _gold.withValues(alpha: 0.6)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (top != null)
            Text(
              top,
              style: const TextStyle(
                color: Color(0xFFE9D9B4),
                fontSize: 8.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
          Text(
            main,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bigContent(BuildContext context) {
    final d = widget.untilShow;
    String two(int n) => n.toString().padLeft(2, '0');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (_live) ...[
              const _LiveDot(),
              const SizedBox(width: 8),
              const Text(
                'LIVE NOW',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.8,
                ),
              ),
            ] else ...[
              const Icon(Icons.emoji_events_rounded, color: _gold, size: 16),
              const SizedBox(width: 6),
              const Text(
                'TONIGHT · 6PM PT',
                style: TextStyle(
                  color: _gold,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: _foil(context, 'MAIN STAGE', 42),
        ),
        const SizedBox(height: 6),
        Text(
          _live ? 'The Belt is on the line' : 'Win the Belt',
          style: TextStyle(
            fontFamily: context.palette.display,
            color: Colors.white,
            fontSize: 19,
            fontVariations: const [FontVariation('wght', 700)],
          ),
        ),
        if (widget.sponsor != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'presented by ${widget.sponsor}',
              style: const TextStyle(
                color: Color(0xFFE9D9B4),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
        const Spacer(),
        if (_live)
          Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFFFD76A), Color(0xFFD9A52E)],
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.play_arrow_rounded, color: Color(0xFF2A1600)),
                SizedBox(width: 4),
                Text(
                  'WATCH LIVE',
                  style: TextStyle(
                    color: Color(0xFF2A1600),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          )
        else
          Row(
            children: [
              _box(two(d.inHours), 'HRS'),
              const SizedBox(width: 8),
              _box(two(d.inMinutes % 60), 'MIN'),
              const SizedBox(width: 8),
              _box(two(d.inSeconds % 60), 'SEC'),
            ],
          ),
      ],
    );
  }

  Widget _box(String v, String l) {
    return Container(
      width: 56,
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _gold.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          Text(
            v,
            style: TextStyle(
              fontFamily: context.palette.display,
              color: Colors.white,
              fontSize: 20,
              fontVariations: const [FontVariation('wght', 800)],
            ),
          ),
          Text(
            l,
            style: const TextStyle(
              color: Color(0xFFE9D9B4),
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.35).animate(_c),
      child: Container(
        width: 9,
        height: 9,
        decoration: const BoxDecoration(
          color: _liveRed,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: _liveRed, blurRadius: 8)],
        ),
      ),
    );
  }
}

/// Marquee bulbs around the card's edge, lit in a three-phase chase.
class _BulbPainter extends CustomPainter {
  _BulbPainter(this.anim, {required this.spacing}) : super(repaint: anim);

  final Animation<double> anim;
  final double spacing;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 6.0;
    final pts = <Offset>[];
    for (var x = 18.0; x <= size.width - 18; x += spacing) {
      pts.add(Offset(x, inset));
    }
    for (var y = 18.0; y <= size.height - 18; y += spacing) {
      pts.add(Offset(size.width - inset, y));
    }
    for (var x = size.width - 18; x >= 18; x -= spacing) {
      pts.add(Offset(x, size.height - inset));
    }
    for (var y = size.height - 18; y >= 18; y -= spacing) {
      pts.add(Offset(inset, y));
    }
    final glow = Paint()
      ..color = const Color(0xFFFFD66E)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final bulb = Paint();
    for (var i = 0; i < pts.length; i++) {
      // Each bulb peaks once per cycle, offset by its phase (i % 3).
      final phase = ((anim.value * 3) - (i % 3)) % 3;
      final lit = math.max(0.0, 1 - (phase - 0.5).abs() * 1.6);
      final a = 0.22 + 0.78 * lit;
      if (lit > 0.05) {
        canvas.drawCircle(
          pts[i],
          4.5,
          glow..color = const Color(0xFFFFD66E).withValues(alpha: lit * 0.8),
        );
      }
      canvas.drawCircle(
        pts[i],
        2.6,
        bulb..color = const Color(0xFFFFE7A6).withValues(alpha: a),
      );
    }
  }

  @override
  bool shouldRepaint(_BulbPainter old) => false;
}

/// A soft diagonal band of light that sweeps across the card now and then.
class _ShinePainter extends CustomPainter {
  _ShinePainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    // Rest for the first 60% of the cycle, sweep across in the last 40%.
    if (t < 0.6) return;
    final k = (t - 0.6) / 0.4;
    final w = size.width * 0.35;
    final x = -w + (size.width + 2 * w) * k;
    final rect = Rect.fromLTWH(x - w / 2, 0, w, size.height);
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0x00FFF0C8), Color(0x52FFF0C8), Color(0x00FFF0C8)],
      ).createShader(rect);
    canvas.save();
    canvas.translate(rect.center.dx, rect.center.dy);
    canvas.skew(-0.3, 0);
    canvas.translate(-rect.center.dx, -rect.center.dy);
    canvas.drawRect(rect.inflate(20), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShinePainter old) => old.t != t;
}
