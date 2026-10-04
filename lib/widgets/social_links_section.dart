import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/social_links.dart';

const Color _kFollowPink = Color(0xFFFF3B6B);

/// The fame page's curated external links, shown as tappable chips. Every tap
/// goes through a "you're leaving The Bully League" confirmation before opening
/// the link in the browser - required discipline for an 18+ app pointing out to
/// external sites. Renders nothing when the performer has set no links.
class SocialLinksSection extends StatelessWidget {
  const SocialLinksSection({super.key, required this.links, this.centered = true});

  final Map<String, String> links;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) return const SizedBox.shrink();
    final chips = <Widget>[];
    for (final p in kSocialPlatforms) {
      final value = links[p.key];
      if (value == null) continue;
      chips.add(_LinkChip(platform: p, value: value));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment:
          centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(
          'FIND ME ON',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          alignment: centered ? WrapAlignment.center : WrapAlignment.start,
          spacing: 8,
          runSpacing: 8,
          children: chips,
        ),
      ],
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.platform, required this.value});

  final SocialPlatform platform;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => _openWithConfirm(context, platform, value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: Colors.white.withValues(alpha: 0.06),
            border: Border.all(color: _kFollowPink.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(platform.icon, size: 16, color: _kFollowPink),
              const SizedBox(width: 7),
              Text(
                platform.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirm, then open the external link. Shared so the editor's preview and the
/// public page open links the same, safe way.
Future<void> _openWithConfirm(
    BuildContext context, SocialPlatform platform, String value) async {
  final url = socialUrl(platform.key, value);
  if (url == null) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Leaving The Bully League'),
      content: Text(
          'This opens ${platform.label} in your browser. We can\'t vouch for '
          'anything outside the app.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('Open ${platform.label}'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open that link.")),
      );
    }
  }
}
