import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../core/services/event_window.dart';

/// Keeps [kWindowLive] (and [kWindowName]) in step with the daily Sixes and
/// Sevens window, so the app can show its LIVE CUE (WindowLiveBar) while the
/// hour is on and hide it afterwards.
///
/// It used to drive an automatic app-wide skin swap (Nightlife); that was
/// dropped for brand consistency (see kWindowSkin in app.dart), and Nightlife
/// became an unlockable prestige skin. This controller now drives the live
/// cue instead of the theme - kept high in the signed-in tree so the cue is
/// available on every signed-in surface, battlers and spectators alike.
///
/// The window is a wall-clock event (it opens at 6pm Pacific whether or not
/// anyone touches the app), so liveness is re-evaluated on a timer as well
/// as when the config changes - a purely event-driven check would miss the
/// boundary for anyone sitting on an idle screen at 6:00.
class WindowSkinController extends StatefulWidget {
  const WindowSkinController({super.key, required this.child});

  final Widget child;

  @override
  State<WindowSkinController> createState() => _WindowSkinControllerState();
}

class _WindowSkinControllerState extends State<WindowSkinController> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _configSub;
  Timer? _timer;
  // Defaults to the documented 6-7pm Pacific window, so an unreadable
  // config never leaves the app unable to decide - it just uses the
  // canonical hours, same as the countdown banner.
  EventWindowConfig _config = const EventWindowConfig();

  @override
  void initState() {
    super.initState();
    _configSub = FirebaseFirestore.instance
        .collection('config')
        .doc('eventWindow')
        .snapshots()
        .listen(
      (snap) {
        _config = EventWindowConfig.fromMap(snap.data());
        _recompute();
      },
      // A config read failure must never strand the theme: keep the
      // default hours and carry on.
      onError: (_) => _recompute(),
    );
    // 30s granularity means the swap lands within half a minute of the
    // hour boundary, which is imperceptible for a theme and far cheaper
    // than a per-second tick.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _recompute());
    // The initial evaluation is deferred to AFTER this frame, deliberately.
    // initState runs during the parent StreamBuilder's build, and _recompute
    // sets kWindowLive, whose listener updates kActiveTheme - which is
    // listened to by an ANCESTOR (the MaterialApp). Mutating it during build
    // tries to mark that ancestor dirty mid-build, which Flutter drops - so
    // on a COLD START already inside the window the base skin would stick and
    // the `!=` guard below would then stop the config-snapshot and timer
    // recomputes from ever re-firing (kWindowLive is already correct; only
    // kActiveTheme was missed). Same reason _AccountStatusGate restores the
    // equipped skin in a post-frame callback. The config listener and the
    // timer already fire outside build, so only this first pass needs it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recompute();
    });
  }

  void _recompute() {
    final now = DateTime.now();
    // A disabled window is never live, so no LIVE cue shows - a broken or
    // retired promo must not light the app up.
    final live = _config.enabled &&
        currentOrNextWindow(now, _config).contains(now);
    if (kWindowLive.value != live) kWindowLive.value = live;
    // Keep the cue's label in step with the (console-tunable) name.
    if (kWindowName.value != _config.name) kWindowName.value = _config.name;
  }

  @override
  void dispose() {
    _configSub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
