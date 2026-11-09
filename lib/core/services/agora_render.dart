import 'package:flutter/foundation.dart';

/// Whether Agora video is drawn as a Flutter texture instead of a native view.
///
/// iOS ONLY. By default Agora puts each video in a native UIView, and on the
/// iPhone those native views ended up drawn ON TOP of the Flutter widgets
/// meant to sit over them: mid-battle the chess clocks, the Yield button, the
/// opening countdown and the "Passing mic in 3..." warning were all present in
/// the widget tree yet invisible (confirmed with the widget inspector on a
/// real iPhone, 2026-11-08). A Flutter texture is composited by Flutter like
/// any image, so overlays always stay on top. Android keeps its default
/// TextureView, which already layers correctly and was never affected.
bool get agoraUseFlutterTexture => defaultTargetPlatform == TargetPlatform.iOS;
