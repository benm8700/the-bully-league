import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/social_links.dart';

/// Lets a performer set their curated external links (handles for Instagram /
/// TikTok / YouTube / X, URLs for a website / tickets). Writes the normalised
/// values to users/{uid}.profile.links. Own-profile only.
class SocialLinksEditor extends StatefulWidget {
  const SocialLinksEditor({super.key, required this.initialLinks, this.onSaved});

  final Map<String, String> initialLinks;
  final VoidCallback? onSaved;

  @override
  State<SocialLinksEditor> createState() => _SocialLinksEditorState();
}

class _SocialLinksEditorState extends State<SocialLinksEditor> {
  late final Map<String, TextEditingController> _controllers = {
    for (final p in kSocialPlatforms)
      p.key: TextEditingController(
        text: _display(p.key, widget.initialLinks[p.key]),
      ),
  };
  final Map<String, String?> _errors = {};
  bool _saving = false;

  /// Handles are stored bare; show them with a leading @ so the field reads
  /// naturally. URLs are shown as stored.
  String _display(String key, String? stored) {
    if (stored == null || stored.isEmpty) return '';
    final p = socialPlatform(key);
    if (p?.type == SocialFieldType.handle) return '@$stored';
    return stored;
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _saving) return;
    final map = <String, String>{};
    final errors = <String, String?>{};
    for (final p in kSocialPlatforms) {
      final raw = _controllers[p.key]!.text.trim();
      if (raw.isEmpty) continue;
      final norm = normalizeSocialValue(p.key, raw);
      if (norm == null) {
        errors[p.key] = p.type == SocialFieldType.handle
            ? 'That doesn\'t look like a handle'
            : 'That doesn\'t look like a link';
      } else {
        map[p.key] = norm;
      }
    }
    setState(() => _errors
      ..clear()
      ..addAll(errors));
    if (errors.isNotEmpty) return;

    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({'profile.links': map});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Links saved')),
        );
        widget.onSaved?.call();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't save your links.")),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your links',
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
          'Shown on your fame page so fans can find you. Add a handle or a '
          'link - leave the rest blank.',
          style: text.bodySmall
              ?.copyWith(color: Colors.white.withValues(alpha: 0.6)),
        ),
        const SizedBox(height: 12),
        for (final p in kSocialPlatforms) ...[
          TextField(
            controller: _controllers[p.key],
            keyboardType: p.type == SocialFieldType.url
                ? TextInputType.url
                : TextInputType.text,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              prefixIcon: Icon(p.icon, size: 20),
              labelText: p.label,
              hintText: p.hint,
              errorText: _errors[p.key],
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 2),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving...' : 'Save links'),
          ),
        ),
      ],
    );
  }
}
