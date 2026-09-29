import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/follows_service.dart';
import '../../widgets/emoji_stats_card.dart';
import '../../widgets/follow_button.dart';
import '../../widgets/home/rank_badges.dart';
import '../../widgets/match_clip_player.dart';

/// A comedian's public fame page: name / face / rank / follower count / a
/// Follow button / their published clips.
///
/// PUBLIC FIELDS ONLY. It shows exactly what a fan may see - name, face, rank
/// title, follower count, and clips already made public - and never the
/// private profile fields (hometown, ammo, etc.), which stay hidden per the
/// existing privacy rules. This is where following happens and where a
/// performer sees their own follower count.
///
/// Fame is its OWN axis, so it wears the brand PINK (follow/social), distinct
/// from the skill Ranks board and the gold tournament/event surfaces.
class PerformerProfileScreen extends StatelessWidget {
  const PerformerProfileScreen({
    super.key,
    required this.uid,
    this.seedUsername,
  });

  final String uid;

  /// Optional name to show instantly while the user doc loads.
  final String? seedUsername;

  static const _pink = Color(0xFFFF3B6B);
  static const _bg = Color(0xFF0E0B14);

  static Future<void> open(BuildContext context, String uid,
      {String? username}) {
    return Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PerformerProfileScreen(uid: uid, seedUsername: username),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isMe = FirebaseAuth.instance.currentUser?.uid == uid;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Profile'),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .snapshots(),
        builder: (context, snap) {
          final user = snap.data?.data();
          final username =
              (user?['username'] as String?) ?? seedUsername ?? 'Roaster';
          final rankTitle = user?['rankTitle'] as String?;
          final followers = followerCountOf(user);
          final photo = _firstPhoto(user);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              const SizedBox(height: 8),
              Center(child: _Avatar(photoUrl: photo, size: 96)),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  username,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
              const SizedBox(height: 8),
              // Rank crest + title (their skill identity, the other axis).
              if (rankTitle != null)
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RankBadge(title: rankTitle, size: 26),
                      const SizedBox(width: 6),
                      Text(
                        rankTitle,
                        // Gold for the two top tiers (matching Home/Profile) so
                        // the most prestigious ranks read as prestige.
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: rankTitle == 'Legend' || rankTitle == 'GOAT'
                                  ? const Color(0xFFF4C838)
                                  : Colors.white.withValues(alpha: 0.75),
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 22),
              _FollowerCount(count: followers),
              const SizedBox(height: 18),
              if (!isMe) FollowButton(uid: uid) else const _ThisIsYou(),
              const SizedBox(height: 26),
              EmojiStatsCard(
                counts: (user?['emojiCounts'] as Map?)?.cast<String, dynamic>(),
              ),
              const SizedBox(height: 30),
              _ClipsSection(uid: uid),
            ],
          );
        },
      ),
    );
  }

  static String? _firstPhoto(Map<String, dynamic>? user) {
    final profile = user?['profile'];
    if (profile is Map) {
      final photos = profile['photoUrls'];
      if (photos is List && photos.isNotEmpty && photos.first is String) {
        return photos.first as String;
      }
    }
    return null;
  }
}

class _FollowerCount extends StatelessWidget {
  const _FollowerCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          _formatCount(count),
          style: const TextStyle(
            color: PerformerProfileScreen._pink,
            fontSize: 40,
            fontWeight: FontWeight.w900,
            height: 1.0,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          count == 1 ? 'Follower' : 'Followers',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}

class _ThisIsYou extends StatelessWidget {
  const _ThisIsYou();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'This is your fame page',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.5),
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

/// A circular avatar - the performer's first (face) photo, or a placeholder.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.photoUrl, this.size = 96});

  final String? photoUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF241B33),
        border: Border.all(
            color: PerformerProfileScreen._pink.withValues(alpha: 0.5),
            width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: photoUrl != null
          ? Image.network(photoUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const _AvatarPlaceholder())
          : const _AvatarPlaceholder(),
    );
  }
}

class _AvatarPlaceholder extends StatelessWidget {
  const _AvatarPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(Icons.person,
          size: 48, color: Colors.white.withValues(alpha: 0.35)),
    );
  }
}

/// This performer's published clips. Best-effort: it needs a composite index
/// (player + highlight.published), so a missing index or any error degrades to
/// a clean empty state rather than an error. In beta there are typically no
/// published clips, so this is usually empty for now.
class _ClipsSection extends StatefulWidget {
  const _ClipsSection({required this.uid});

  final String uid;

  @override
  State<_ClipsSection> createState() => _ClipsSectionState();
}

class _ClipsSectionState extends State<_ClipsSection> {
  List<_Clip> _clips = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final clips = <_Clip>[];
    try {
      final db = FirebaseFirestore.instance;
      for (final field in ['player1Id', 'player2Id']) {
        final snap = await db
            .collection('matches')
            .where(field, isEqualTo: widget.uid)
            .where('highlight.published', isEqualTo: true)
            .limit(6)
            .get();
        for (final d in snap.docs) {
          final url = _clipUrl(d.data());
          if (url != null) clips.add(_Clip(matchId: d.id, url: url));
        }
      }
    } catch (_) {
      // Missing index or any read error → just show the empty state.
    }
    if (!mounted) return;
    setState(() {
      _clips = clips;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CLIPS',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        if (_clips.isEmpty)
          Text(
            'No public clips yet.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
          )
        else
          for (final clip in _clips)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: MatchClipPlayer(videoUrl: clip.url),
                ),
              ),
            ),
      ],
    );
  }
}

class _Clip {
  const _Clip({required this.matchId, required this.url});
  final String matchId;
  final String url;
}

String? _clipUrl(Map<String, dynamic> match) {
  final highlight = match['highlight'];
  if (highlight is! Map) return null;
  final urls = highlight['publicUrls'];
  if (urls is Map) {
    return (urls['landscape'] ?? urls['vertical'] ?? urls.values.firstOrNull)
        as String?;
  }
  return null;
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

String _formatCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final k = n / 1000;
    return '${k.toStringAsFixed(k >= 10 ? 0 : 1)}K';
  }
  final m = n / 1000000;
  return '${m.toStringAsFixed(m >= 10 ? 0 : 1)}M';
}
