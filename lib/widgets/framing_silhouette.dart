import 'package:flutter/material.dart';

/// The pre-match framing guide, shared by the camera check and the tutorial so
/// the framing you practise is the framing you see before every battle.
///
/// It is a transparent HEAD OVAL you line your face up in, a light shoulder
/// cue below it (so head AND shoulders land in frame - which is what the
/// stacked highlight composite needs), and a faint ANGRY "game face" inside
/// the oval. The old full-body silhouette locked people into one pose and
/// body shape, so most real people never fit it; an oval only cares about
/// your face, which is all the framing actually needs. The scowl is the
/// on-brand bit - this is a roast app, seen only in-app by signed-in adults
/// during the camera check, so "bring your game face" beats a polite oval.
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
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Head oval - the thing you line your face up with.
    final head = Rect.fromCenter(center: o(0.50, 0.40), width: w * 0.50, height: h * 0.44);
    final headPath = Path()..addOval(head);

    // Neck + shoulder cue: a short neck dropping from under the oval, then
    // two slopes sweeping out to the shoulders - connected to the head so it
    // reads as head-and-shoulders (which the composite crop wants) rather
    // than two lines floating below a face.
    final shoulders = Path()
      ..moveTo(w * 0.50, h * 0.615)
      ..lineTo(w * 0.50, h * 0.665)
      ..moveTo(w * 0.50, h * 0.665)
      ..quadraticBezierTo(w * 0.34, h * 0.695, w * 0.17, h * 0.85)
      ..moveTo(w * 0.50, h * 0.665)
      ..quadraticBezierTo(w * 0.66, h * 0.695, w * 0.83, h * 0.85);

    // Angry "game face" - features drawn as light strokes inside the oval.
    // Eyebrows pinch DOWN toward the centre (the classic scowl); the mouth is
    // a downturned frown. Kept faint so you can still line your own face up.
    final brows = Path()
      // left brow: outer-high to inner-low
      ..moveTo(w * 0.36, h * 0.345)
      ..lineTo(w * 0.465, h * 0.40)
      // right brow: outer-high to inner-low (mirror)
      ..moveTo(w * 0.64, h * 0.345)
      ..lineTo(w * 0.535, h * 0.40);

    final mouth = Path()
      ..moveTo(w * 0.40, h * 0.605)
      ..quadraticBezierTo(w * 0.50, h * 0.545, w * 0.60, h * 0.605);

    // Eyes - small filled dots under the pinched brows.
    final eyeR = w * 0.020;
    final leftEye = o(0.42, 0.455);
    final rightEye = o(0.58, 0.455);

    // Head first (faint fill + outline).
    canvas.drawPath(headPath, fill);
    canvas.drawPath(headPath, under);
    canvas.drawPath(headPath, line);

    // Then the face + shoulders as strokes.
    for (final p in [shoulders, brows, mouth]) {
      canvas.drawPath(p, under);
      canvas.drawPath(p, line);
    }

    // Eyes: a dark halo under a white dot so they read on any background.
    canvas.drawCircle(leftEye, eyeR + 1.2, Paint()..color = Colors.black.withValues(alpha: 0.35));
    canvas.drawCircle(rightEye, eyeR + 1.2, Paint()..color = Colors.black.withValues(alpha: 0.35));
    final eyePaint = Paint()..color = Colors.white.withValues(alpha: 0.85);
    canvas.drawCircle(leftEye, eyeR, eyePaint);
    canvas.drawCircle(rightEye, eyeR, eyePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
