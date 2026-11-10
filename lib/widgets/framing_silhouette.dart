import 'package:flutter/material.dart';

/// The pre-match framing guide, shared by the camera check and the tutorial so
/// the framing you practise is the framing you see before every battle.
///
/// It is a transparent X-eyed grin - just the eyes and mouth, no ring around
/// them (developer's call, 2026-10-07: the circle read as clutter; the floating
/// KO face looks cleaner over the live camera). The X-eyed grin is the on-brand
/// "roasted to death, still laughing" bit; it is only ever seen in-app by
/// signed-in adults during the camera check. The features are still sized and
/// placed off an invisible head radius so they stay proportioned and sit high
/// in the frame on any screen - which keeps the old framing cue (sit back,
/// head-and-shoulders) without drawing the ring.
///
/// Drawn with a dark under-stroke beneath a white line so it stays legible
/// over both a bright and a dark camera feed.
class FramingSilhouette extends StatelessWidget {
  const FramingSilhouette({super.key});

  @override
  Widget build(BuildContext context) {
    // NEON CROWN FACE (developer, 2026-11-09): the brand's pink neon crown
    // floats where the top of your head goes, and the X-eyed grin is drawn in
    // the same neon - "put your head under the crown" is the framing cue.
    // Geometry mirrors _FramingPainter's invisible head circle.
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        final r = w * _headR;
        final crownW = r * 1.1;
        final headTop = h * _headCy - r;
        return Stack(
          children: [
            const Positioned.fill(
              child: CustomPaint(painter: _FramingPainter()),
            ),
            Positioned(
              left: w * 0.5 - crownW / 2,
              width: crownW,
              // Crown's bottom band sits just above the head top.
              bottom: h - headTop + r * 0.08,
              child: Image.asset(
                'assets/branding/bully_league_crown.png',
                fit: BoxFit.contain,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Invisible head circle: centre (0.5w, _headCy*h), radius _headR*w.
const _headCy = 0.40;
const _headR = 0.24;
const _neonPink = Color(0xFFFF2BD6);

class _FramingPainter extends CustomPainter {
  const _FramingPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    Offset o(double fx, double fy) => Offset(w * fx, h * fy);

    // Neon tube look, matching the crown: a wide blurred pink glow, a pink
    // tube, and a thin white-hot core. Legible on bright and dark feeds.
    final under = Paint()
      ..color = _neonPink.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    final tube = Paint()
      ..color = _neonPink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Invisible head radius - the eyes and mouth are sized and placed off it
    // so the KO face stays proportioned and sits high in the frame on any
    // screen, even though the ring itself is no longer drawn. The smaller
    // radius still nudges people to sit BACK (head-and-shoulders) rather than
    // jamming their face into the lens.
    final c = o(0.50, _headCy);
    final r = w * _headR;

    // X eyes: two short crossing strokes each, up and out from the centre.
    final eyeDx = r * 0.42;
    final eyeDy = r * 0.26;
    final e = r * 0.15; // half-size of each X
    final leftEye = c + Offset(-eyeDx, -eyeDy);
    final rightEye = c + Offset(eyeDx, -eyeDy);
    final eyes = Path();
    for (final ec in [leftEye, rightEye]) {
      eyes
        ..moveTo(ec.dx - e, ec.dy - e)
        ..lineTo(ec.dx + e, ec.dy + e)
        ..moveTo(ec.dx - e, ec.dy + e)
        ..lineTo(ec.dx + e, ec.dy - e);
    }

    // Grin: an upturned arc across the lower half of the circle.
    final smileHalf = r * 0.44;
    final smileY = c.dy + r * 0.28;
    final smileDip = r * 0.36;
    final mouth = Path()
      ..moveTo(c.dx - smileHalf, smileY)
      ..quadraticBezierTo(c.dx, smileY + smileDip, c.dx + smileHalf, smileY);

    // The X eyes and the grin as strokes, dark halo under white line. No ring.
    for (final p in [eyes, mouth]) {
      canvas.drawPath(p, under);
      canvas.drawPath(p, tube);
      canvas.drawPath(p, line);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
