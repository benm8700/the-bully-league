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
    return const CustomPaint(
      painter: _FramingPainter(),
      child: SizedBox.expand(),
    );
  }
}

class _FramingPainter extends CustomPainter {
  const _FramingPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    Offset o(double fx, double fy) => Offset(w * fx, h * fy);

    final under = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Invisible head radius - the eyes and mouth are sized and placed off it
    // so the KO face stays proportioned and sits high in the frame on any
    // screen, even though the ring itself is no longer drawn. The smaller
    // radius still nudges people to sit BACK (head-and-shoulders) rather than
    // jamming their face into the lens.
    final c = o(0.50, 0.30);
    final r = w * 0.20;

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
      canvas.drawPath(p, line);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
