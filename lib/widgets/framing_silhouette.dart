import 'package:flutter/material.dart';

/// A framing guide shaped like a person flipping the bird, shared by the
/// pre-match check and the tutorial so the framing you practise is exactly
/// the framing you see before every battle.
///
/// The head-and-shoulders bust is still the functional part - it tells you
/// where to sit so the camera catches you well (propped phone, seated at
/// table distance, a steady shot mattering more than anything). The raised
/// arm and the extended middle finger are attitude: this is a roast app, the
/// guide is only ever seen in-app by signed-in adults during the camera
/// check, and a defiant little ghost sets the tone better than a polite
/// oval did.
///
/// Built as ONE unioned path so the translucent fill never double-blends at
/// the seams, then given a dark under-stroke beneath a white line so it
/// stays legible against both a bright and a dark camera feed.
class FramingSilhouette extends StatelessWidget {
  const FramingSilhouette({super.key});

  @override
  Widget build(BuildContext context) {
    return const CustomPaint(
      painter: _SilhouettePainter(),
      child: SizedBox.expand(),
    );
  }
}

class _SilhouettePainter extends CustomPainter {
  const _SilhouettePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final figure = _figurePath(size);

    final fill = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
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

    canvas.drawPath(figure, fill);
    canvas.drawPath(figure, under);
    canvas.drawPath(figure, line);
  }

  /// The whole figure as a single filled outline: head, neck, torso, the arm
  /// resting at the left, and the right arm raised into a fist with the
  /// middle finger up.
  Path _figurePath(Size size) {
    final w = size.width;
    final h = size.height;
    Offset o(double fx, double fy) => Offset(w * fx, h * fy);

    // Head - the centred anchor you line your face up with. Sized about a
    // third of the shoulder width, which is roughly the real ratio and reads
    // more like a person than the earlier oversized head.
    Path figure = Path()
      ..addOval(Rect.fromCenter(
        center: o(0.50, 0.215),
        width: w * 0.215,
        height: h * 0.165,
      ));

    Path union(Path a, Path b) => Path.combine(PathOperation.union, a, b);

    // Neck - tapered, reaching down far enough to bridge cleanly into the
    // torso so there is no gap at the centre of the chest.
    figure = union(figure, _capsule(o(0.50, 0.275), o(0.50, 0.47), w * 0.044));

    // SLOPED SHOULDERS. Real shoulders fall away from the neck rather than
    // sitting flat, so each is a thick capsule running from the neck base
    // DOWN and out to a rounded deltoid - that slope is most of what makes a
    // silhouette read as a body instead of a bell.
    final neckBaseL = o(0.455, 0.42);
    final neckBaseR = o(0.545, 0.42);
    final deltoidL = o(0.255, 0.50);
    final deltoidR = o(0.70, 0.49);
    figure = union(figure, _capsule(neckBaseL, deltoidL, w * 0.058));
    figure = union(figure, _capsule(neckBaseR, deltoidR, w * 0.058));

    // Torso - a clean upper body with a STRAIGHT top edge (no concave rim),
    // tapering from the shoulders down to a narrower chest/waist so it reads
    // as a person cut off at the chest rather than a wide gown. The resting
    // left arm is folded into this shape; only the right arm is drawn
    // separately, raised.
    final torso = Path()
      ..moveTo(w * 0.25, h * 0.47)
      ..quadraticBezierTo(w * 0.30, h * 0.70, w * 0.35, h * 0.93)
      ..lineTo(w * 0.65, h * 0.93)
      ..quadraticBezierTo(w * 0.70, h * 0.70, w * 0.74, h * 0.47)
      ..close();
    figure = union(figure, torso);

    // Upper-chest filler: a solid trapezoid tucked under the neck and over
    // the shoulder/torso seam. Purely interior - it closes the little gaps
    // that would otherwise leave stroked holes where the neck, the two
    // sloped shoulders and the torso top all meet.
    final chest = Path()
      ..moveTo(w * 0.36, h * 0.44)
      ..lineTo(w * 0.64, h * 0.44)
      ..lineTo(w * 0.70, h * 0.55)
      ..lineTo(w * 0.30, h * 0.55)
      ..close();
    figure = union(figure, chest);

    // Right arm raised, bent at the elbow: deltoid -> elbow (out and up) ->
    // wrist (forearm rising, tucked slightly inward). Tapers from a fuller
    // upper arm to a slimmer forearm.
    final elbow = o(0.81, 0.31);
    final wrist = o(0.725, 0.185);
    figure = union(figure, _capsule(deltoidR, elbow, w * 0.056));
    figure = union(figure, _capsule(elbow, wrist, w * 0.046));

    // Fist - a little fuller than the forearm so it reads as a closed hand.
    figure = union(
      figure,
      Path()
        ..addOval(Rect.fromCenter(
          center: o(0.72, 0.15),
          width: w * 0.145,
          height: h * 0.066,
        )),
    );

    // The middle finger, standing up out of the fist - the whole point.
    figure = union(figure, _capsule(o(0.72, 0.135), o(0.72, 0.055), w * 0.029));

    return figure;
  }

  /// A rounded "capsule" (a thick line with round ends) as a fillable path,
  /// built from the connecting quad plus a circle at each end. Used for the
  /// neck, the two arm segments and the finger so every joint unions into
  /// the body without a seam.
  Path _capsule(Offset a, Offset b, double r) {
    final d = b - a;
    final len = d.distance;
    if (len < 1e-3) {
      return Path()..addOval(Rect.fromCircle(center: a, radius: r));
    }
    final ux = d.dx / len;
    final uy = d.dy / len;
    final px = -uy * r; // perpendicular offset
    final py = ux * r;
    final quad = Path()
      ..moveTo(a.dx + px, a.dy + py)
      ..lineTo(b.dx + px, b.dy + py)
      ..lineTo(b.dx - px, b.dy - py)
      ..lineTo(a.dx - px, a.dy - py)
      ..close();
    Path out = Path.combine(PathOperation.union, quad,
        Path()..addOval(Rect.fromCircle(center: a, radius: r)));
    out = Path.combine(PathOperation.union, out,
        Path()..addOval(Rect.fromCircle(center: b, radius: r)));
    return out;
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
