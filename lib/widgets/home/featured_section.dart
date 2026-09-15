import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// One item in the Home "Featured" spotlight - a curated/promotional clip or
/// event (see CLAUDE.md's Discovery/feed "Featured" decision: paid/promotional
/// comedian matches get their own spotlight, distinct from Top 5 and Trending).
class FeaturedItem {
  const FeaturedItem({
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final String? imageUrl;
  final VoidCallback? onTap;
}

/// The Home "Featured" section - a horizontal row of spotlight cards.
///
/// INTENTIONALLY HIDDEN AT LAUNCH, AND THAT IS THE POINT. There is no real
/// featured content yet, so with an empty [items] list this renders
/// **absolutely nothing** - no heading, no placeholder cards, no "Coming
/// Soon", no blank space. An empty section on Home would read as a bug or an
/// unfinished app; showing nothing is correct until there is genuine curated
/// content to show.
///
/// The architecture (this widget, [FeaturedItem], and [_FeaturedCard]) is
/// built and MUST NOT BE REMOVED just because it is currently invisible - it
/// is the home for promotional/comedian spotlight clips when that pipeline is
/// switched on. To light it up later, feed it a non-empty [items] list (from a
/// `featured` Firestore collection or a curated config, plus the matching
/// read rule); nothing else here needs to change.
class FeaturedSection extends StatelessWidget {
  const FeaturedSection({super.key, this.items = const []});

  final List<FeaturedItem> items;

  @override
  Widget build(BuildContext context) {
    // Zero real content -> render nothing at all (see the class doc).
    if (items.isEmpty) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Text(
            'Featured',
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        SizedBox(
          height: 168,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, i) => _FeaturedCard(item: items[i]),
          ),
        ),
      ],
    );
  }
}

/// A single featured spotlight card: artwork with a title/subtitle overlay.
class _FeaturedCard extends StatelessWidget {
  const _FeaturedCard({required this.item});

  final FeaturedItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: item.onTap,
        child: SizedBox(
          width: 240,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: item.imageUrl != null
                    ? Image.network(
                        item.imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const ColoredBox(
                          color: Color(0xFF201A26),
                        ),
                      )
                    : const ColoredBox(color: Color(0xFF201A26)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: context.palette.accent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
