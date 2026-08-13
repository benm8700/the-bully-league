import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'video_call_service.dart';

/// Everything i420ToJpeg needs, bundled into one object so the conversion
/// can run via Flutter's compute() (a background isolate) - isolate entry
/// points take exactly one argument, and this is real per-pixel work over
/// a full video frame (hundreds of thousands of pixels), not something to
/// run on the UI thread every few seconds without a hitch.
class I420FrameData {
  const I420FrameData({
    required this.width,
    required this.height,
    required this.yStride,
    required this.uStride,
    required this.vStride,
    required this.yBuffer,
    required this.uBuffer,
    required this.vBuffer,
    this.quality = 70,
  });

  factory I420FrameData.fromRawVideoFrame(RawVideoFrame frame, {int quality = 70}) {
    return I420FrameData(
      width: frame.width,
      height: frame.height,
      yStride: frame.yStride,
      uStride: frame.uStride,
      vStride: frame.vStride,
      yBuffer: frame.yBuffer,
      uBuffer: frame.uBuffer,
      vBuffer: frame.vBuffer,
      quality: quality,
    );
  }

  final int width;
  final int height;
  final int yStride;
  final int uStride;
  final int vStride;
  final Uint8List yBuffer;
  final Uint8List uBuffer;
  final Uint8List vBuffer;
  final int quality;
}

/// Converts an I420 (YUV420 planar) frame to JPEG bytes using the standard
/// BT.601 conversion formula. Needed because Agora's VideoFrameObserver
/// callbacks deliver raw YUV420 pixel data (see CLAUDE.md's step 9a status
/// note), not a format Cloud Vision or anything else can consume directly.
///
/// Top-level function (not a method) so it can be passed to compute().
Uint8List i420ToJpeg(I420FrameData data) {
  final width = data.width;
  final height = data.height;
  final yBuffer = data.yBuffer;
  final uBuffer = data.uBuffer;
  final vBuffer = data.vBuffer;
  final image = img.Image(width: width, height: height);

  for (var y = 0; y < height; y++) {
    final yRowStart = y * data.yStride;
    // U/V planes are subsampled 2x2 in I420 - one chroma sample covers a
    // 2x2 luma block, hence the halved row index here.
    final uvRowStart = (y >> 1) * data.uStride;
    for (var x = 0; x < width; x++) {
      final yValue = yBuffer[yRowStart + x];
      final uvIndex = uvRowStart + (x >> 1);
      final uValue = uBuffer[uvIndex];
      final vValue = vBuffer[uvIndex];

      final c = yValue - 16;
      final d = uValue - 128;
      final e = vValue - 128;

      final r = ((298 * c + 409 * e + 128) >> 8).clamp(0, 255);
      final g = ((298 * c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255);
      final b = ((298 * c + 516 * d + 128) >> 8).clamp(0, 255);

      image.setPixelRgb(x, y, r, g, b);
    }
  }

  return img.encodeJpg(image, quality: data.quality);
}
