import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../screens/rewards/rewards_screen.dart';
import '../home/rank_badges.dart';

/// The bottom bar with the RANK CREST in the middle (2026-11-11 redesign,
/// developer's call - the big rank card left Home and lives here instead).
///
///   Home · Battles · (crest) · Ranks · N pts
///
/// THE CREST IS THE XP BAR. It shows the crest of the title you're working
/// TOWARD, blacked out, and reveals it bottom-up as your XP grows: fully
/// revealed = a few points from the next title. Under it: your title + XP and
/// how much is left. Tapping it opens your profile.
///
/// +XP POP-UP: the XP total you were last shown is stored on your user doc
/// (`xpSeen`). Whenever Home is on screen and your XP is higher than that
/// (after a battle, judging, or coming back to the app later - even on another
/// phone), a "+N XP" pop-up plays while the crest uncovers the new amount,
/// then `xpSeen` catches up. A first-ever load just records the total, so
/// nobody is greeted by "+2,000 XP".
///
/// Judge is no longer a tab: Home's big JUDGE door opens the same feed.
class CrestNavBar extends StatelessWidget {
  const CrestNavBar({
    super.key,
    required this.index,
    required this.onSelect,
    required this.homeVisible,
  });

  /// The shell's current tab index (0 Home, 1 Judge feed, 2 My Battles,
  /// 3 Ranks, 4 Profile).
  final int index;
  final ValueChanged<int> onSelect;

  /// Only show the +XP pop-up while Home is the screen in front.
  final bool homeVisible;

  static const double _barHeight = 70;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Container(
      height: _barHeight + bottom,
      padding: EdgeInsets.only(bottom: bottom),
      decoration: BoxDecoration(
        color: const Color(0xFF0E0A14),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Row(
            children: [
              _NavItem(
                icon: Icons.home_outlined,
                activeIcon: Icons.home,
                label: 'Home',
                active: index == 0,
                onTap: () => onSelect(0),
              ),
              _NavItem(
                icon: Icons.emoji_events_outlined,
                activeIcon: Icons.emoji_events,
                label: 'Battles',
                active: index == 2,
                onTap: () => onSelect(2),
              ),
              const Expanded(child: SizedBox()),
              _NavItem(
                icon: Icons.leaderboard_outlined,
                activeIcon: Icons.leaderboard,
                label: 'Ranks',
                active: index == 3,
                onTap: () => onSelect(3),
              ),
              if (uid != null)
                _PointsItem(uid: uid)
              else
                const Expanded(child: SizedBox()),
            ],
          ),
          if (uid != null)
            Positioned(
              left: 0,
              right: 0,
              top: -30,
              child: Center(
                child: _CrestButton(
                  uid: uid,
                  active: index == 4,
                  homeVisible: homeVisible,
                  onTap: () => onSelect(4),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

const Color _gold = Color(0xFFF4C838);
const Color _pink = Color(0xFFFF5EA0);
const Color _idle = Color(0xFF9A91A8);

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? _pink : _idle;
    return Expanded(
      child: Semantics(
        button: true,
        selected: active,
        label: label,
        child: InkResponse(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(active ? activeIcon : icon, color: color, size: 24),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "N pts" - the spendable balance, tapping through to Rewards.
class _PointsItem extends StatelessWidget {
  const _PointsItem({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .snapshots(),
        builder: (context, snap) {
          final balance =
              (snap.data?.data()?['pointsBalance'] as num?)?.toInt() ?? 0;
          return Semantics(
            button: true,
            label: '$balance points. Open rewards.',
            child: InkResponse(
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const RewardsScreen())),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.redeem_outlined, color: _gold, size: 24),
                  const SizedBox(height: 3),
                  Text(
                    '$balance pts',
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The raised crest: the next title's crest, revealed bottom-up by XP.
class _CrestButton extends StatefulWidget {
  const _CrestButton({
    required this.uid,
    required this.active,
    required this.homeVisible,
    required this.onTap,
  });

  final String uid;
  final bool active;
  final bool homeVisible;
  final VoidCallback onTap;

  @override
  State<_CrestButton> createState() => _CrestButtonState();
}

class _CrestButtonState extends State<_CrestButton> {
  static const double _size = 58;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  Map<String, dynamic>? _meter;
  int? _points;
  int? _xpSeen;
  bool _seenLoaded = false;
  int? _meterForPoints; // which XP total the loaded meter belongs to

  // The fill the crest is ANIMATING FROM (null = no animation, jump).
  double? _fromFill;
  int? _toastGain;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    _sub = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.uid)
        .snapshots()
        .listen((snap) {
          final d = snap.data();
          final pts = (d?['points'] as num?)?.toInt() ?? 0;
          final seen = (d?['xpSeen'] as num?)?.toInt();
          final changed = pts != _points;
          _points = pts;
          _xpSeen = seen;
          _seenLoaded = true;
          if (changed) _loadMeter();
          _maybeCelebrate();
        }, onError: (_) {});
  }

  @override
  void didUpdateWidget(_CrestButton old) {
    super.didUpdateWidget(old);
    if (widget.homeVisible && !old.homeVisible) _maybeCelebrate();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _toastTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadMeter() async {
    final forPoints = _points;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final r = await FirebaseFunctions.instance
            .httpsCallable('getLaughMeter')
            .call<Map<String, dynamic>>();
        if (!mounted) return;
        setState(() {
          _meter = r.data;
          _meterForPoints = forPoints;
        });
        _maybeCelebrate();
        return;
      } catch (_) {
        if (!mounted) return;
        await Future.delayed(Duration(milliseconds: 600 * (1 << attempt)));
      }
    }
  }

  double get _fill => ((_meter?['fill'] as num?)?.toDouble() ?? 0).clamp(0, 1);

  /// Plays "+N XP" once per gain, only with Home in front and the meter for
  /// the new XP total loaded, then records it as seen.
  void _maybeCelebrate() {
    final pts = _points;
    if (!_seenLoaded || pts == null || !mounted) return;
    final seen = _xpSeen;
    if (seen == null) {
      // First time ever: just record where they are - no pop-up.
      _writeSeen(pts);
      return;
    }
    if (pts <= seen) return;
    if (!widget.homeVisible || _meterForPoints != pts || _toastGain != null) {
      return;
    }
    final gain = pts - seen;
    // Where the crest was before the gain, inside the current title's band
    // (clamped - a gain that crossed a title starts from empty).
    final tierXp = (_meter?['tierXp'] as num?)?.toDouble();
    final nextXp = (_meter?['nextXp'] as num?)?.toDouble();
    double from = 0;
    if (tierXp != null && nextXp != null && nextXp > tierXp) {
      from = ((seen - tierXp) / (nextXp - tierXp)).clamp(0, 1).toDouble();
    }
    setState(() {
      _toastGain = gain;
      _fromFill = from;
    });
    _writeSeen(pts);
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 3200), () {
      if (mounted) {
        setState(() {
          _toastGain = null;
          _fromFill = null;
        });
      }
    });
  }

  void _writeSeen(int pts) {
    _xpSeen = pts;
    FirebaseFirestore.instance
        .collection('users')
        .doc(widget.uid)
        .set({'xpSeen': pts}, SetOptions(merge: true))
        .catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final title = _meter?['title'] as String?;
    final nextTitle = _meter?['nextTitle'] as String?;
    final xp = (_meter?['xp'] as num?)?.toInt() ?? _points ?? 0;
    final nextXp = (_meter?['nextXp'] as num?)?.toInt();
    // The crest being revealed: the NEXT title's, or your own at the top.
    final asset = rankBadgeAsset(nextTitle) ?? rankBadgeAsset(title);
    final left = nextXp == null ? null : nextXp - xp;
    final line1 = title == null
        ? 'YOUR RANK'
        : '${title.toUpperCase()} · $xp XP';
    final line2 = left == null
        ? (title == 'GOAT' ? 'Top of the league' : '')
        : left <= 0
        ? 'Level up!'
        : '$left XP to $nextTitle';

    return Semantics(
      button: true,
      label: 'Your rank. $line1. $line2',
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: _size + 8,
                  height: _size + 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF0E0A14),
                    border: Border.all(
                      color: widget.active
                          ? _pink
                          : _gold.withValues(alpha: 0.35 + 0.5 * _fill),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.12 + 0.45 * _fill),
                        blurRadius: 18,
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: asset == null
                      ? const Icon(Icons.shield, color: _gold, size: 34)
                      : TweenAnimationBuilder<double>(
                          key: ValueKey('reveal-$_fromFill-$_fill'),
                          tween: Tween(begin: _fromFill ?? _fill, end: _fill),
                          duration: Duration(
                            milliseconds: _fromFill == null ? 0 : 1600,
                          ),
                          curve: Curves.easeOutCubic,
                          builder: (context, f, _) =>
                              _RevealCrest(asset: asset, fill: f, size: _size),
                        ),
                ),
                const SizedBox(height: 2),
                MediaQuery.withNoTextScaling(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        line1,
                        maxLines: 1,
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.4,
                        ),
                      ),
                      if (line2.isNotEmpty)
                        Text(
                          line2,
                          maxLines: 1,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            // The +XP pop-up, floating above the crest.
            if (_toastGain != null)
              Positioned(
                top: -44,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOutBack,
                  builder: (context, t, child) => Opacity(
                    opacity: t.clamp(0, 1),
                    child: Transform.translate(
                      offset: Offset(0, 10 * (1 - t)),
                      child: child,
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _gold,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 12),
                      ],
                    ),
                    child: Text(
                      '+$_toastGain XP',
                      style: const TextStyle(
                        color: Color(0xFF2A1600),
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A crest drawn twice: blacked out underneath, and in full colour clipped to
/// the bottom [fill] fraction on top - so it "uncovers" upward as XP grows.
class _RevealCrest extends StatelessWidget {
  const _RevealCrest({
    required this.asset,
    required this.fill,
    required this.size,
  });

  final String asset;
  final double fill;
  final double size;

  static const _blackout = ColorFilter.matrix(<double>[
    0.05, 0.12, 0.02, 0, 0, //
    0.05, 0.12, 0.02, 0, 0, //
    0.05, 0.12, 0.02, 0, 0, //
    0, 0, 0, 1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    final img = Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          ColorFiltered(colorFilter: _blackout, child: img),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ClipRect(
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: fill.clamp(0.0, 1.0),
                child: img,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
