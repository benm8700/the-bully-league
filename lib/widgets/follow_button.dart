import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/services/follows_service.dart';

/// The brand PINK - fame is its own axis (follow/social), distinct from the
/// skill Ranks board and the gold tournament/event surfaces.
const Color kFollowPink = Color(0xFFFF3B6B);

/// A reusable Follow / Following toggle, driven live by follow membership.
///
/// Renders NOTHING for your own account or when signed out - you cannot
/// follow yourself, and a "Follow" button on your own clip reads as a bug.
///
/// [compact] gives a small pill for tight rows, sheets, and over-video
/// overlays; the default is the full-width button used on the fame page. Both
/// carry their own solid backgrounds so the pink "Follow" and the translucent
/// "Following" stay legible over a bright clip as well as on a dark surface.
class FollowButton extends StatefulWidget {
  const FollowButton({super.key, required this.uid, this.compact = false});

  final String uid;
  final bool compact;

  @override
  State<FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends State<FollowButton> {
  final _service = FollowsService();
  bool _busy = false;

  bool get _isSelf =>
      FirebaseAuth.instance.currentUser?.uid == widget.uid;

  @override
  Widget build(BuildContext context) {
    if (_isSelf || FirebaseAuth.instance.currentUser == null) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<bool>(
      stream: _service.isFollowing(widget.uid),
      builder: (context, snap) {
        final following = snap.data ?? false;
        return widget.compact
            ? _compact(following)
            : _full(following);
      },
    );
  }

  Widget _full(bool following) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: following
          ? OutlinedButton.icon(
              onPressed: _busy ? null : () => _toggle(false),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Following'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.4)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            )
          : FilledButton.icon(
              onPressed: _busy ? null : () => _toggle(true),
              icon: const Icon(Icons.person_add_alt_1, size: 18),
              label: const Text('Follow'),
              style: FilledButton.styleFrom(
                backgroundColor: kFollowPink,
                foregroundColor: Colors.white,
                textStyle:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
    );
  }

  Widget _compact(bool following) {
    final bg = following ? Colors.white.withValues(alpha: 0.14) : kFollowPink;
    final fg = Colors.white;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _busy ? null : () => _toggle(!following),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(following ? Icons.check : Icons.person_add_alt_1,
                  size: 15, color: fg),
              const SizedBox(width: 5),
              Text(
                following ? 'Following' : 'Follow',
                style: TextStyle(
                    color: fg, fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggle(bool follow) async {
    setState(() => _busy = true);
    try {
      if (follow) {
        await _service.follow(widget.uid);
      } else {
        await _service.unfollow(widget.uid);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
