import 'package:flutter/material.dart';

/// Curated external links for a comedian's fame page - the payoff of following
/// someone (see their socials, shows, tickets). DELIBERATELY CURATED, not
/// free-text: the performer enters just a handle (or a URL for the website /
/// tickets fields) for a FIXED set of platforms, and the app builds the link.
/// Pointing out of an 18+ app is a store-review/safety surface, so the shape is
/// constrained and every tap goes through a "you're leaving the app" confirm.
///
/// Stored at users/{uid}.profile.links as a {platformKey: value} map, where the
/// value is the already-normalised handle/URL. Pure helpers here build and
/// validate, so they are unit-tested without Firestore.

enum SocialFieldType { handle, url }

class SocialPlatform {
  const SocialPlatform({
    required this.key,
    required this.label,
    required this.icon,
    required this.type,
    required this.hint,
  });

  final String key;
  final String label;
  final IconData icon;
  final SocialFieldType type;

  /// Placeholder shown in the editor field.
  final String hint;
}

/// The fixed, curated platform set (order = display order).
const List<SocialPlatform> kSocialPlatforms = [
  SocialPlatform(
      key: 'instagram',
      label: 'Instagram',
      icon: Icons.camera_alt_outlined,
      type: SocialFieldType.handle,
      hint: '@yourhandle'),
  SocialPlatform(
      key: 'tiktok',
      label: 'TikTok',
      icon: Icons.music_note_outlined,
      type: SocialFieldType.handle,
      hint: '@yourhandle'),
  SocialPlatform(
      key: 'youtube',
      label: 'YouTube',
      icon: Icons.play_circle_outline,
      type: SocialFieldType.handle,
      hint: '@yourchannel'),
  SocialPlatform(
      key: 'x',
      label: 'X',
      icon: Icons.alternate_email,
      type: SocialFieldType.handle,
      hint: '@yourhandle'),
  SocialPlatform(
      key: 'website',
      label: 'Website',
      icon: Icons.language,
      type: SocialFieldType.url,
      hint: 'yoursite.com'),
  SocialPlatform(
      key: 'tickets',
      label: 'Tickets',
      icon: Icons.confirmation_number_outlined,
      type: SocialFieldType.url,
      hint: 'link to your shows'),
];

SocialPlatform? socialPlatform(String key) {
  for (final p in kSocialPlatforms) {
    if (p.key == key) return p;
  }
  return null;
}

/// Allowed characters in a social handle. Deliberately strict so a handle field
/// can't smuggle in a full URL or an injection - just letters, digits, and the
/// few punctuation marks real handles use.
final RegExp _handleChars = RegExp(r'^[A-Za-z0-9._-]{1,40}$');

/// Normalise a raw editor value for SAVING. Returns null when empty or invalid
/// (the field is then cleared). Pure.
///
/// Handle fields: strip a leading @ and surrounding whitespace, and if someone
/// pasted a profile URL, take its last path segment - then validate the handle
/// charset. URL fields: trim, add https:// if no scheme, and require an
/// http(s) URL with a dotted host.
String? normalizeSocialValue(String key, String raw) {
  final p = socialPlatform(key);
  if (p == null) return null;
  var v = raw.trim();
  if (v.isEmpty) return null;

  if (p.type == SocialFieldType.handle) {
    // If they pasted a URL, keep the last non-empty path segment.
    if (v.contains('/')) {
      final parts = v.split('/').where((s) => s.isNotEmpty).toList();
      if (parts.isNotEmpty) v = parts.last;
    }
    v = v.replaceAll('@', '').trim();
    if (!_handleChars.hasMatch(v)) return null;
    return v;
  }

  // URL field.
  if (!v.contains('://')) v = 'https://$v';
  final uri = Uri.tryParse(v);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (!uri.hasAuthority || !uri.host.contains('.')) return null;
  return uri.toString();
}

/// Build the full external URL to open from a STORED value. Pure.
String? socialUrl(String key, String value) {
  final v = value.trim();
  if (v.isEmpty) return null;
  switch (key) {
    case 'instagram':
      return 'https://instagram.com/$v';
    case 'tiktok':
      return 'https://www.tiktok.com/@$v';
    case 'youtube':
      return 'https://www.youtube.com/@$v';
    case 'x':
      return 'https://x.com/$v';
    case 'website':
    case 'tickets':
      return v; // already a normalised URL
    default:
      return null;
  }
}

/// Read the links map off a user document defensively, keeping only known
/// platforms with a non-empty value.
Map<String, String> socialLinksOf(Map<String, dynamic>? user) {
  final profile = user?['profile'];
  final raw = profile is Map ? profile['links'] : null;
  final out = <String, String>{};
  if (raw is Map) {
    for (final p in kSocialPlatforms) {
      final v = raw[p.key];
      if (v is String && v.trim().isNotEmpty) out[p.key] = v.trim();
    }
  }
  return out;
}
