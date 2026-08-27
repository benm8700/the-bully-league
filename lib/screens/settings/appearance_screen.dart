import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../theme/app_theme.dart';

/// Where a player picks their app SKIN - the proof-of-concept for earned
/// prestige themes (CLAUDE.md's earned-skins decision).
///
/// Card is the base everyone gets; Neon is an unlockable prestige skin,
/// earned at GOAT and kept forever after (like the XP titles - earned and
/// never lost). A skin is pure presentation: it drives the app theme via
/// [kActiveTheme] and touches nothing server-side, so a hacked skin harms
/// nobody - which is why the unlock is a plain client-visible check rather
/// than a guarded write.
///
/// The equipped skin persists on the user document (`equippedSkin`), so it
/// follows the account across devices; `unlockedSkins` records what has been
/// earned so a skin stays yours even after you drop out of the tier that
/// granted it.
class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final ref = uid == null
        ? null
        : FirebaseFirestore.instance.collection('users').doc(uid);

    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ref == null
          ? const Center(child: Text('Sign in to change your look.'))
          : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: ref.snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final data = snapshot.data!.data() ?? {};
                final rankTitle = data['rankTitle'] as String?;
                final equipped =
                    (data['equippedSkin'] as String?) ?? kThemeIds.first;
                final unlocked = ((data['unlockedSkins'] as List?) ?? const [])
                    .whereType<String>()
                    .toSet();

                // Earn-once, keep-forever: reaching GOAT permanently unlocks
                // Neon. Recorded the moment it is seen, so it survives a
                // later drop from the top five.
                if (rankTitle == 'GOAT' && !unlocked.contains('neon')) {
                  ref.set({
                    'unlockedSkins': FieldValue.arrayUnion(['neon']),
                  }, SetOptions(merge: true));
                }

                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      'Your look',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Card is yours from the start. Prestige skins are '
                      'earned - and once earned, kept.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    for (final skin in _skins)
                      _SkinTile(
                        skin: skin,
                        equipped: equipped == skin.id,
                        unlocked: skin.id == kThemeIds.first ||
                            unlocked.contains(skin.id) ||
                            (skin.id == 'neon' && rankTitle == 'GOAT'),
                        onEquip: () {
                          // Immediate (drives the app theme now) and
                          // persisted (follows the account).
                          kActiveTheme.value = skin.id;
                          ref.set({'equippedSkin': skin.id},
                              SetOptions(merge: true));
                        },
                      ),
                  ],
                );
              },
            ),
    );
  }
}

/// A skin option: an app theme, a display name, a tier label, and (for
/// locked ones) how it is earned.
class _Skin {
  const _Skin({
    required this.id,
    required this.name,
    required this.tier,
    this.unlockHint,
  });

  final String id;
  final String name;
  final String tier;
  final String? unlockHint;
}

const _skins = <_Skin>[
  _Skin(id: 'card', name: 'Card', tier: 'Base'),
  _Skin(
    id: 'neon',
    name: 'Neon',
    tier: 'Prestige',
    unlockHint: 'Reach GOAT to unlock',
  ),
];

class _SkinTile extends StatelessWidget {
  const _SkinTile({
    required this.skin,
    required this.equipped,
    required this.unlocked,
    required this.onEquip,
  });

  final _Skin skin;
  final bool equipped;
  final bool unlocked;
  final VoidCallback onEquip;

  @override
  Widget build(BuildContext context) {
    // The tile previews the skin in ITS OWN colours, not the current
    // theme's - so a player sees what they would be equipping.
    final theme = appTheme(skin.id);
    final palette = theme.extension<AppPalette>()!;
    final scheme = theme.colorScheme;
    final text = Theme.of(context).textTheme;

    return Opacity(
      opacity: unlocked ? 1 : 0.6,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: equipped ? palette.accent : scheme.outlineVariant,
            width: equipped ? 2 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // A swatch painted in the skin's gauge gradient + accent, so
              // the two directions read as visibly different at a glance.
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [palette.gaugeFrom, palette.gaugeTo],
                  ),
                  border: Border.all(color: palette.accent, width: 1.5),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(skin.name,
                            style: text.titleMedium?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: palette.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(skin.tier,
                              style: text.labelSmall
                                  ?.copyWith(color: palette.accent)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      unlocked
                          ? (equipped ? 'Equipped' : 'Tap to equip')
                          : (skin.unlockHint ?? 'Locked'),
                      style: text.bodySmall?.copyWith(
                          color: unlocked
                              ? scheme.onSurfaceVariant
                              : scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (!unlocked)
                Icon(Icons.lock_outline, color: scheme.onSurfaceVariant)
              else if (equipped)
                Icon(Icons.check_circle, color: palette.accent)
              else
                TextButton(onPressed: onEquip, child: const Text('Equip')),
            ],
          ),
        ),
      ),
    );
  }
}
