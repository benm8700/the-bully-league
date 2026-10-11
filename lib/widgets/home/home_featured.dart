import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../match_clip_player.dart';
import 'featured_section.dart';

/// The live data source for the Home "Featured" spotlight. Streams the
/// `featured` collection (the founder's Editor's Choice picks, written only
/// from the /admin dashboard) and feeds [FeaturedSection].
///
/// Degrades to nothing: loading, empty, or an error all render an empty
/// FeaturedSection, which draws absolutely nothing - a featured row that
/// failed to load must never leave a broken-looking gap on Home. The doc is
/// denormalised (player names + an optional public clip url) so this is one
/// cheap listener with no per-item lookups.
class HomeFeatured extends StatelessWidget {
  const HomeFeatured({super.key});

  @override
  Widget build(BuildContext context) {
    final query = FirebaseFirestore.instance
        .collection('featured')
        .orderBy('pickedAt', descending: true)
        .limit(10);
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const FeaturedSection();
        final items = <FeaturedItem>[];
        for (final doc in snap.data!.docs) {
          final d = doc.data();
          final p1 = (d['player1Name'] as String?)?.trim();
          final p2 = (d['player2Name'] as String?)?.trim();
          if (p1 == null || p1.isEmpty || p2 == null || p2.isEmpty) continue;
          final clipUrl = (d['clipUrl'] as String?)?.trim();
          final hasClip = clipUrl != null && clipUrl.isNotEmpty;
          final title = '$p1 vs $p2';
          items.add(FeaturedItem(
            title: title,
            subtitle: '⭐ Editor\'s Choice',
            playable: hasClip,
            onTap: hasClip
                ? () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            _FeaturedClipScreen(title: title, url: clipUrl),
                      ),
                    )
                : null,
          ));
        }
        return FeaturedSection(items: items);
      },
    );
  }
}

/// A plain full-screen player for a featured battle's published clip.
class _FeaturedClipScreen extends StatelessWidget {
  const _FeaturedClipScreen({required this.title, required this.url});

  final String title;
  final String url;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title),
      ),
      body: Center(child: MatchClipPlayer(videoUrl: url)),
    );
  }
}
