import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// THE BATTLE CARD (2026-11-14, developer's call): name, where you're from
/// and "about me" - what an opponent sees about you. Filled in ONCE by the
/// ranked setup flow the first time a player taps Ranked, then kept off the
/// Profile page (it was a form people only fill once, and made the profile
/// feel like paperwork). Edited from Settings > Battle card, where name, city
/// and country can change only once every [kBattleCardCooldown] (clearing is
/// always allowed - safety and privacy), and "about me" any time.

const Duration kBattleCardCooldown = Duration(days: 30);

/// The setup steps a player still needs before ranked.
enum SetupStep { name, location, selfie, intro, about }

String _s(Object? v) => (v is String) ? v.trim() : '';

/// Which steps to show. Intro video and selfie are always required (the
/// server's enterQueue gates). Name, location and about are asked once, the
/// first time through - after `profile.rankedSetupDoneAt` is set, only a
/// missing intro/selfie brings the flow back.
List<SetupStep> setupStepsNeeded(Map<String, dynamic>? user) {
  final p = (user?['profile'] as Map?)?.cast<String, dynamic>() ?? const {};
  final done = p['rankedSetupDoneAt'] != null;
  return [
    if (!done && _s(p['name']).isEmpty) SetupStep.name,
    if (!done && _s(p['country']).isEmpty) SetupStep.location,
    if (_s(p['facePhotoUrl']).isEmpty) SetupStep.selfie,
    if (_s(p['introVideoUrl']).isEmpty) SetupStep.intro,
    if (!done && _s(p['ammoText']).isEmpty) SetupStep.about,
  ];
}

/// Runs the server's profile-text check (hate speech, etc.). Returns the
/// field keys that were refused; empty = fine. Throws on network failure.
Future<List<String>> blockedProfileFields(Map<String, String> fields) async {
  final check = await FirebaseFunctions.instance
      .httpsCallable('checkProfileText')
      .call<Map<String, dynamic>>({'fields': fields});
  return ((check.data['blocked'] as List?) ?? const []).cast<String>();
}

const String kProfileTextRefused =
    "That isn't allowed. Roasts are fine, but no hate speech and nothing "
    'sexual involving kids.';

/// Writes profile fields (already checked) onto the user doc.
Future<void> saveProfileFields(
  DocumentReference<Map<String, dynamic>> userRef,
  Map<String, Object?> fields,
) {
  return userRef.update({
    for (final e in fields.entries) 'profile.${e.key}': e.value,
  });
}

/// When the locked fields (name, city, country) may next be CHANGED, or null
/// if they may change now. Filling a blank or clearing is always allowed.
DateTime? battleCardLockedUntil(Map<String, dynamic>? user) {
  final p = (user?['profile'] as Map?)?.cast<String, dynamic>() ?? const {};
  final at = p['battleCardChangedAt'];
  final ms = at is Timestamp
      ? at.millisecondsSinceEpoch
      : (at is num ? at.toInt() : null);
  if (ms == null) return null;
  final until = DateTime.fromMillisecondsSinceEpoch(
    ms,
  ).add(kBattleCardCooldown);
  return until.isAfter(DateTime.now()) ? until : null;
}

/// True when going from [before] to [after] is a CHANGE that the cooldown
/// covers: both non-empty and different. Filling a blank or clearing isn't.
bool isLockedChange(String before, String after) =>
    before.trim().isNotEmpty &&
    after.trim().isNotEmpty &&
    before.trim() != after.trim();
