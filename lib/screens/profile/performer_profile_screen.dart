import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/follows_service.dart';
import '../../core/social_links.dart';
import '../../theme/house_theme.dart';
import '../../widgets/belt_flair.dart';
import '../../widgets/emoji_stats_card.dart';
import '../../widgets/social_links_section.dart';
import '../moderation/report_screen.dart';
import '../../widgets/follow_button.dart';
import '../../widgets/home/rank_badges.dart';
import '../../widgets/looping_video.dart';
import '../../widgets/match_clip_player.dart';

/// A comedian's public fame page: name / face / rank / follower count / a
/// Follow button / their published clips / a STUDY CARD (their intro video +
/// "about me").
///
/// The study card is deliberate (2026-10-17): the intro video is now the real
/// ammo, and someone recorded it KNOWING opponents study it, so letting anyone
/// watch it here - reachable from Ranks and The Cut, so finalists can prep -
/// is the point. "About me" is volunteered text, so it's fair game too. CITY &
/// STATE stays OFF this page (the one bit of real-world location data; it's
/// shown only to a matched opponent in the bio reveal).
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

  static Future<void> open(
    BuildContext context,
    String uid, {
    String? username,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PerformerProfileScreen(uid: uid, seedUsername: username),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMe = FirebaseAuth.instance.currentUser?.uid == uid;
    return Scaffold(
      backgroundColor: _bg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Profile'),
        actions: [
          // A neutral overflow menu (not a prominent flag) so a profile - or a
          // bad external link on it - can be reported, without inviting
          // trigger-happy reports. Mirrors the feed's report discipline and
          // keeps Apple 1.2 flagging reachable on this surface too. Never on
          // your own profile.
          if (!isMe)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: 'More',
              onSelected: (v) {
                if (v == 'report') {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ReportScreen(reportedUserId: uid),
                    ),
                  );
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'report',
                  child: Text('Report this player'),
                ),
              ],
            ),
        ],
      ),
      // THE NEON ROOM (developer, 2026-11-18: "spruce it up, like our
      // theme"): the same club backdrop as your own Profile, a scrim, and
      // the page on top.
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/home/profile_background.png',
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x66000000),
                    Color(0x8C0E0B14),
                    Color(0xF20E0B14),
                  ],
                  stops: [0.0, 0.45, 0.8],
                ),
              ),
            ),
          ),
          SafeArea(
            child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
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
                  // Clear of the transparent app bar (the body runs behind it).
                  padding: const EdgeInsets.fromLTRB(20, 48, 20, 32),
                  children: [
                    Center(
                      child: _HeroAvatar(photoUrl: photo, name: username),
                    ),
                    const SizedBox(height: 10),
                    Center(
                      child: Text(
                        username,
                        textAlign: TextAlign.center,
                        style: House.display(size: 34, color: Colors.white)
                            .copyWith(
                              shadows: const [
                                Shadow(
                                  color: Color(0xCCFF2E7E),
                                  blurRadius: 18,
                                ),
                                Shadow(color: Colors.black87, blurRadius: 4),
                              ],
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
                            RankBadge(title: rankTitle, size: 40),
                            const SizedBox(width: 8),
                            Text(
                              rankTitle,
                              // Gold for the two top tiers (matching Home/Profile) so
                              // the most prestigious ranks read as prestige.
                              style: TextStyle(
                                fontSize: 20,
                                color:
                                    rankTitle == 'Legend' || rankTitle == 'GOAT'
                                    ? const Color(0xFFF4C838)
                                    : Colors.white.withValues(alpha: 0.85),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            // The ladder rung as a Roman numeral ("· V"), matching
                            // Home/Profile. Absent for GOAT and unknown titles.
                            if (rankTierNumeral(rankTitle) != null) ...[
                              Text(
                                '  ·  ',
                                style: TextStyle(
                                  fontSize: 20,
                                  color: Colors.white.withValues(alpha: 0.4),
                                ),
                              ),
                              Text(
                                rankTierNumeral(rankTitle)!,
                                style: TextStyle(
                                  fontSize: 20,
                                  color:
                                      rankTierColor(rankTitle) ??
                                      const Color(0xFFF4C838),
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    const SizedBox(height: 14),
                    Center(child: BeltFlair(uid: uid)),
                    const SizedBox(height: 22),
                    // Followers beside their GLOBAL RANK (developer, 2026-11-18:
                    // the rank is public on the board anyway, so show it here).
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xCC140D1D),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: const Color(
                            0xFFFF2E7E,
                          ).withValues(alpha: 0.45),
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFFFF2E7E,
                            ).withValues(alpha: 0.22),
                            blurRadius: 24,
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Expanded(child: _FollowerCount(count: followers)),
                          Container(
                            width: 1,
                            height: 44,
                            color: Colors.white12,
                          ),
                          Expanded(
                            child: _GlobalRank(rating: user?['rating'] as num?),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (!isMe) FollowButton(uid: uid) else const _ThisIsYou(),
                    const SizedBox(height: 26),
                    _StudyCard(user: user),
                    EmojiStatsCard(
                      counts: (user?['emojiCounts'] as Map?)
                          ?.cast<String, dynamic>(),
                    ),
                    if (socialLinksOf(user).isNotEmpty) ...[
                      const SizedBox(height: 30),
                      SocialLinksSection(links: socialLinksOf(user)),
                    ],
                    const SizedBox(height: 30),
                    _ClipsSection(uid: uid),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String? _firstPhoto(Map<String, dynamic>? user) {
    final profile = user?['profile'];
    if (profile is Map) {
      final face = profile['facePhotoUrl'];
      if (face is String && face.isNotEmpty) return face;
      final photos = profile['photoUrls'];
      if (photos is List && photos.isNotEmpty && photos.first is String) {
        return photos.first as String;
      }
    }
    return null;
  }
}

/// The intro video (looping, sound on - it's a performance) and the
/// volunteered "about me", with no heading (developer, 2026-11-18: the
/// "Study them" title and its explainer line are gone - just the video).
/// Renders nothing if the player has neither. City & State is deliberately
/// NOT here.
class _StudyCard extends StatelessWidget {
  const _StudyCard({required this.user});

  final Map<String, dynamic>? user;

  @override
  Widget build(BuildContext context) {
    final profile = user?['profile'];
    final intro = profile is Map ? profile['introVideoUrl'] as String? : null;
    final about = profile is Map ? profile['ammoText'] as String? : null;
    final hasIntro = intro != null && intro.trim().isNotEmpty;
    final hasAbout = about != null && about.trim().isNotEmpty;
    if (!hasIntro && !hasAbout) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasIntro)
          Align(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 360),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFFB64DFF).withValues(alpha: 0.7),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFB64DFF).withValues(alpha: 0.35),
                    blurRadius: 26,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(19),
                child: LoopingVideo(url: intro),
              ),
            ),
          ),
        if (hasAbout) ...[
          if (hasIntro) const SizedBox(height: 14),
          // Rounded corners + a one-sided border can't share a decoration,
          // so the clip rounds it.
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              decoration: const BoxDecoration(
                color: Color(0xCC140D1D),
                border: Border(
                  left: BorderSide(color: Color(0xFFFF2E7E), width: 4),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.zero,
                child: Text(
                  about,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 30),
      ],
    );
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

/// Their position on the Ranks board: players out-rating them, +1 - the same
/// count the Home card's GLOBAL RANK and the board use. Shows only the
/// position, never the hidden rating. Nothing for an unplaced account.
class _GlobalRank extends StatefulWidget {
  const _GlobalRank({required this.rating});

  final num? rating;

  @override
  State<_GlobalRank> createState() => _GlobalRankState();
}

class _GlobalRankState extends State<_GlobalRank> {
  int? _rank;
  num? _for;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_GlobalRank old) {
    super.didUpdateWidget(old);
    if (old.rating != widget.rating) _load();
  }

  Future<void> _load() async {
    final rating = widget.rating;
    if (rating == null || rating == _for) return;
    _for = rating;
    // The count() aggregation is server-only, so a cold start can fail it
    // once; retry a few times (same as the Home card).
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final ahead = await FirebaseFirestore.instance
            .collection('users')
            .where('rating', isGreaterThan: rating)
            .count()
            .get();
        if (mounted) setState(() => _rank = (ahead.count ?? 0) + 1);
        return;
      } catch (_) {
        if (!mounted) return;
        await Future.delayed(Duration(milliseconds: 600 * (1 << attempt)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          _rank == null ? '-' : '#$_rank',
          style: const TextStyle(
            color: Color(0xFFF4C838),
            fontSize: 40,
            fontWeight: FontWeight.w900,
            height: 1.0,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Global rank',
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
          width: 2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: photoUrl != null
          ? Image.network(
              photoUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const _AvatarPlaceholder(),
            )
          : const _AvatarPlaceholder(),
    );
  }
}

class _AvatarPlaceholder extends StatelessWidget {
  const _AvatarPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        Icons.person,
        size: 48,
        color: Colors.white.withValues(alpha: 0.35),
      ),
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
  // SUBSCRIBER PERK (2026-11-11, developer's call): only subscribers get
  // their approved (published) clips shown on their profile. The clips stay
  // published for the website/socials either way - this only gates the
  // profile display. While config/monetization.enabled is false (no way to
  // subscribe yet) everyone qualifies, same as the other subscriber perks.
  bool _gated = false;

  /// Mirrors functions/entitlement.js isSubscriber: explicit active:true, and
  /// an expiry in the future (or none = open-ended).
  static bool _isSubscriber(Map<String, dynamic>? user) {
    final sub = user?['subscription'];
    if (sub is! Map || sub['active'] != true) return false;
    final exp = (sub['expiresAtMs'] as num?)?.toInt() ?? 0;
    return exp <= 0 || DateTime.now().millisecondsSinceEpoch < exp;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final clips = <_Clip>[];
    var gated = false;
    try {
      final db = FirebaseFirestore.instance;
      final monetization =
          (await db.collection('config').doc('monetization').get()).data();
      if (monetization?['enabled'] == true) {
        final user = (await db.collection('users').doc(widget.uid).get())
            .data();
        gated = !_isSubscriber(user);
      }
      if (gated) throw const _Gated();
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
    } on _Gated {
      // Not a subscriber: no clips on the profile.
    } catch (_) {
      // Missing index or any read error → just show the empty state.
    }
    if (!mounted) return;
    setState(() {
      _clips = clips;
      _gated = gated;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final mine = FirebaseAuth.instance.currentUser?.uid == widget.uid;
    // Other people see nothing at all for a non-subscriber; the owner sees
    // what they'd get.
    if (_gated && !mine) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'FEATURED CLIPS',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        if (_gated)
          Text(
            'Subscribers can show their featured clips here.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
          )
        else if (_clips.isEmpty)
          Text(
            'No featured clips yet.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
          )
        else
          for (final clip in _clips)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              // The stacked 9:16 cut (top/bottom), sized so it doesn't
              // swallow the whole profile.
              child: Center(
                child: SizedBox(
                  height: 460,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AspectRatio(
                      aspectRatio: 9 / 16,
                      child: MatchClipPlayer(videoUrl: clip.url),
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}

class _Gated implements Exception {
  const _Gated();
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
    // Vertical = stacked top/bottom, the phone cut. Landscape (side by side)
    // is the website's.
    return (urls['vertical'] ?? urls['landscape'] ?? urls.values.firstOrNull)
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

/// The profile's hero: their selfie in a neon ring (pink -> purple -> gold)
/// with a pink glow, under a soft spotlight - the "star of the show" look.
class _HeroAvatar extends StatelessWidget {
  const _HeroAvatar({required this.photoUrl, required this.name});

  final String? photoUrl;
  final String name;

  static const double _size = 148;
  static const double _ring = 5;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      height: _size + 40,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Spotlight.
          Container(
            width: 260,
            height: _size + 40,
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                colors: [Color(0x40FFFFFF), Color(0x00FFFFFF)],
                stops: [0.0, 0.7],
              ),
            ),
          ),
          // Ring + glow.
          Container(
            width: _size,
            height: _size,
            padding: const EdgeInsets.all(_ring),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                colors: [
                  Color(0xFFFF2E7E),
                  Color(0xFFB64DFF),
                  Color(0xFFF4C838),
                  Color(0xFFFF2E7E),
                ],
              ),
              boxShadow: [
                BoxShadow(color: Color(0x99FF2E7E), blurRadius: 28),
                BoxShadow(color: Color(0x66B64DFF), blurRadius: 50),
              ],
            ),
            child: Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF0E0B14),
              ),
              padding: const EdgeInsets.all(3),
              child: _Avatar(photoUrl: photoUrl, size: _size - _ring * 2 - 6),
            ),
          ),
        ],
      ),
    );
  }
}
