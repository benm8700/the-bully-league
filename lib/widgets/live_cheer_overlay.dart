import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/emoji_ratings.dart';

/// Ephemeral live "crowd energy" over a Main Stage battle: tap an emoji and it
/// floats up on EVERY viewer's screen for a moment.
///
/// This is PURE VIBE and deliberately separate from the one-per-battle reaction
/// ([LiveReactionPanel]). A cheer is unlimited, touches no permanent identity
/// count and no verdict, and vanishes - so it needs no heavy guard: signed-in,
/// own-write, a light client rate cap, and the docs self-expire via a Firestore
/// TTL policy on `expireAt`. That is why the crowd can cheer freely while the
/// RATING that feeds a roaster's real stats stays one-per-account.
///
/// Wraps the video [child] in a Stack: the live video underneath, floating
/// cheers over it, and the tap bar pinned at the bottom.
class LiveCheerOverlay extends StatefulWidget {
  const LiveCheerOverlay({
    super.key,
    required this.matchId,
    required this.child,
  });

  final String matchId;
  final Widget child;

  @override
  State<LiveCheerOverlay> createState() => _LiveCheerOverlayState();
}

class _LiveCheerOverlayState extends State<LiveCheerOverlay>
    with TickerProviderStateMixin {
  // The four reaction emojis double as the cheer vocabulary - cheer or jeer,
  // same glyphs the ratings use. (red_flag is deliberately excluded - it means
  // "crossed the line", a report signal, not crowd energy.)
  static const _cheerKeys = ['fire', 'clever', 'boring', 'trash'];

  // Only animate cheers sent AFTER this screen opened - never replay a backlog.
  final int _mountMs = DateTime.now().millisecondsSinceEpoch;
  final Set<String> _seen = {};
  final List<_Float> _floats = [];
  final Random _rng = Random();
  int _lastSendMs = 0;

  CollectionReference<Map<String, dynamic>> get _cheers =>
      FirebaseFirestore.instance
          .collection('liveReactions')
          .doc(widget.matchId)
          .collection('cheers');

  Future<void> _send(String emojiKey) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastSendMs < 250) return; // ~4/sec client cap
    _lastSendMs = nowMs;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final ref = await _cheers.add({
        'emoji': emojiKey,
        'uid': uid,
        'atMs': nowMs,
        // Self-expiry: a Firestore TTL policy on this field sweeps old cheers,
        // so the ephemeral vibe never becomes unbounded storage.
        'expireAt':
            Timestamp.fromMillisecondsSinceEpoch(nowMs + 5 * 60 * 1000),
      });
      // We already floated this one locally on tap (instant feedback), so mark
      // it seen to skip the stream echo and avoid a double float.
      _seen.add(ref.id);
    } catch (_) {
      // Vibe only - a dropped cheer is harmless, never surface an error.
    }
  }

  void _spawn(String emojiKey) {
    if (!mounted) return;
    final ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600));
    final float = _Float(
      id: UniqueKey(),
      emoji: emojiCharFor(emojiKey),
      ctrl: ctrl,
      dx: _rng.nextDouble(),
    );
    setState(() => _floats.add(float));
    ctrl.forward();
    ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        ctrl.dispose();
        if (mounted) setState(() => _floats.remove(float));
      }
    });
  }

  @override
  void dispose() {
    for (final f in _floats) {
      f.ctrl.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        // Detector: streams cheers sent since we opened and spawns a float for
        // each new one. Renders nothing itself.
        Positioned.fill(
          child: IgnorePointer(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _cheers
                  .where('atMs', isGreaterThan: _mountMs)
                  .orderBy('atMs')
                  .limitToLast(40)
                  .snapshots(),
              builder: (context, snap) {
                for (final d in snap.data?.docs ?? const []) {
                  if (_seen.add(d.id)) {
                    final k = d.data()['emoji'] as String?;
                    if (k != null) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _spawn(k);
                      });
                    }
                  }
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
        // The floats themselves, over the video, ignoring taps.
        Positioned.fill(
          child: IgnorePointer(
            child: Stack(children: _floats.map(_buildFloat).toList()),
          ),
        ),
        // The tap bar, pinned bottom-centre over the video.
        Positioned(
          left: 0,
          right: 0,
          bottom: 10,
          child: Center(child: _cheerBar()),
        ),
      ],
    );
  }

  Widget _buildFloat(_Float f) {
    return AnimatedBuilder(
      animation: f.ctrl,
      builder: (context, _) {
        final t = f.ctrl.value;
        // Rise from low over the video toward the top, with a little sideways
        // drift; fade in fast, fade out toward the end.
        final x = -0.75 + 1.5 * f.dx + 0.12 * sin(t * pi);
        final y = 0.75 - 1.5 * t;
        final opacity =
            (t < 0.12 ? t / 0.12 : (1 - (t - 0.12) / 0.88)).clamp(0.0, 1.0);
        return Align(
          alignment: Alignment(x.clamp(-1.0, 1.0), y),
          child: Opacity(
            opacity: opacity,
            child: Text(f.emoji, style: const TextStyle(fontSize: 34)),
          ),
        );
      },
    );
  }

  Widget _cheerBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final k in _cheerKeys)
            InkWell(
              onTap: () {
                _send(k);
                _spawn(k); // instant local feedback; the stream floats it for others
              },
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(emojiCharFor(k), style: const TextStyle(fontSize: 24)),
              ),
            ),
        ],
      ),
    );
  }
}

class _Float {
  _Float({required this.id, required this.emoji, required this.ctrl, required this.dx});
  final Key id;
  final String emoji;
  final AnimationController ctrl;
  final double dx;
}
