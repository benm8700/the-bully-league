import 'package:flutter/material.dart';

/// The pre-match framing guide, shared by the camera check and the tutorial so
/// the framing you practise is the framing you see before every battle.
///
/// It is a transparent smiley face - a circle you line your own face up in,
/// with X eyes and a grin. The X-eyed grin is the on-brand "roasted to death,
/// still laughing" bit; it is only ever seen in-app by signed-in adults during
/// the camera check, so a playful KO face beats a plain oval. The old
/// full-body silhouette locked people into one pose and body shape, so most
/// real people never fit it; a face circle only cares about your head, which
/// is all the framing actually needs.
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

    final fill = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..style = PaintingStyle.fill;
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

    // Face circle - the thing you line your head up with. Everything else is
    // sized off its radius so the smiley stays proportioned on any screen.
    final c = o(0.50, 0.30);
    // Deliberately smaller than face-filling: a smaller circle makes people
    // sit BACK from the camera (framing head-and-shoulders) rather than
    // pressing their face right up to the lens. Sat high in the frame so
    // there is no wasted dead space above the head.
    final r = w * 0.20;
    final headPath = Path()..addOval(Rect.fromCircle(center: c, radius: r));

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

    // Circle first (faint fill + outline).
    canvas.drawPath(headPath, fill);
    canvas.drawPath(headPath, under);
    canvas.drawPath(headPath, line);

    // Then the X eyes and the grin as strokes, dark halo under white line.
    for (final p in [eyes, mouth]) {
      canvas.drawPath(p, under);
      canvas.drawPath(p, line);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
