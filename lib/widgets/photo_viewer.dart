import 'package:flutter/material.dart';

/// Opens [url] full-screen in a dim lightbox so a small photo can be seen
/// clearly: pinch and drag to zoom, tap the backdrop or the close button to
/// dismiss. Shown uncropped (BoxFit.contain) rather than circle-cropped like
/// the thumbnail it opened from, which is the whole point - you came here to
/// get a clearer look at the actual picture.
void showPhotoViewer(BuildContext context, String url) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      // Not opaque + a dim barrier = a lightbox over the current screen,
      // rather than a full page push that hides it.
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black87,
      pageBuilder: (_, _, _) => _PhotoViewer(url: url),
      transitionsBuilder: (_, anim, _, child) =>
          FadeTransition(opacity: anim, child: child),
    ),
  );
}

class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Transparent so the dim barrier shows the screen underneath.
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Tapping anywhere off the image dismisses, so there's always an
          // obvious way out even before the photo loads.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
          Center(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              // A little room to pan past the edges once zoomed in.
              boundaryMargin: const EdgeInsets.all(64),
              child: Image.network(
                url,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : const SizedBox(
                        width: 48,
                        height: 48,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                errorBuilder: (_, _, _) => const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    "Couldn't load the photo.",
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ),
          ),
          // Explicit close, since a zoomed-in image can cover the backdrop.
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
