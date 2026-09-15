import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/services/auth_service.dart';
import '../../core/services/push_notification_service.dart';
import '../../core/services/visual_moderation_service.dart';
import '../account/delete_account_screen.dart';
import '../settings/appearance_screen.dart';
import '../settings/blocked_players_screen.dart';
import 'form_card.dart';
import 'intro_video_card.dart';

const int kRequiredPhotoCount = 5;

/// Editable profile fields per CLAUDE.md's User Profile System - the
/// "ammo" a roaster gives opponents instead of relying purely on
/// appearance-based improv, plus the 5-photo requirement (Build Order
/// step 9a - deferred from step 7 specifically to land alongside visual
/// moderation, since accepting a photo without running it through
/// moderation first would violate CLAUDE.md's Content Policy & Moderation
/// section). Manual profile approval (approvalStatus) is a separate V1
/// admin workflow via the Firebase console, not enforced by this screen.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.embedded = false});

  /// True when shown as a bottom-nav tab.
  final bool embedded;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  final _professionController = TextEditingController();
  final _educationController = TextEditingController();
  final _hometownController = TextEditingController();
  final _interestsController = TextEditingController();
  final _relationshipStatusController = TextEditingController();
  final _petsController = TextEditingController();
  final _favoriteFoodController = TextEditingController();
  final _ammoTextController = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _signingOut = false;

  /// Listed unless explicitly opted out, mirroring the server's rule that
  /// only a literal `false` hides someone. Defaulting to hidden would
  /// leave the directory permanently empty for every existing account.
  bool _directoryListed = true;
  String? _statusMessage;
  List<String> _photoUrls = [];

  /// Read-only identity shown at the top of the screen. The username is
  /// deliberately NOT editable here (developer's call, 2026-09-14): a profile
  /// is where you see who you are, not where you are nudged to rename yourself.
  /// The backend setUsername still exists for signup, so this is reversible.
  String? _username;
  String? _rankTitle;

  DocumentReference<Map<String, dynamic>> get _userRef => FirebaseFirestore
      .instance
      .collection('users')
      .doc(FirebaseAuth.instance.currentUser!.uid);

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final snapshot = await _userRef.get();
    final profile = snapshot.data()?['profile'] as Map<String, dynamic>? ?? {};
    _professionController.text = profile['profession'] as String? ?? '';
    _educationController.text = profile['education'] as String? ?? '';
    _hometownController.text = profile['hometown'] as String? ?? '';
    _interestsController.text = profile['interests'] as String? ?? '';
    _relationshipStatusController.text = profile['relationshipStatus'] as String? ?? '';
    _petsController.text = profile['pets'] as String? ?? '';
    _favoriteFoodController.text = profile['favoriteFood'] as String? ?? '';
    _ammoTextController.text = profile['ammoText'] as String? ?? '';
    final photoUrls = (profile['photoUrls'] as List<dynamic>?)?.cast<String>() ?? [];
    final listed = snapshot.data()?['directoryListed'];
    final username = snapshot.data()?['username'] as String?;
    final rankTitle = snapshot.data()?['rankTitle'] as String?;
    if (mounted) {
      setState(() {
        _photoUrls = photoUrls;
        _directoryListed = listed != false;
        _username = username;
        _rankTitle = rankTitle;
        _loading = false;
      });
    }
  }

  /// Written immediately rather than waiting for Save. Someone switching
  /// this off wants to stop being findable now, not after they remember
  /// to press a button at the bottom of the screen.
  Future<void> _setDirectoryListed(bool value) async {
    setState(() {
      _directoryListed = value;
      _saving = true;
      _statusMessage = null;
    });
    try {
      await _userRef.update({'directoryListed': value});
      if (mounted) {
        setState(() => _statusMessage = value
            ? 'People can find you by name.'
            : 'You no longer appear in search.');
      }
    } catch (e) {
      // Reverted on failure, so the switch never claims a state the
      // server does not have.
      if (mounted) {
        setState(() {
          _directoryListed = !value;
          _statusMessage = 'Could not change that. Try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _statusMessage = null;
    });
    try {
      // photoUrls is handled separately (each photo writes itself via
      // arrayUnion as soon as it's approved - see _addPhoto) rather than
      // through this batched save, since photo moderation has its own
      // async, per-photo success/failure flow that doesn't map cleanly
      // onto a single "Save" button. Firestore rules only pin rating/
      // rankTitle/rankedMatchesPlayed/wins/losses/accountStatus, so this
      // update is otherwise unrestricted for the owning user.
      await _userRef.update({
        'profile.profession': _professionController.text.trim(),
        'profile.education': _educationController.text.trim(),
        'profile.hometown': _hometownController.text.trim(),
        'profile.interests': _interestsController.text.trim(),
        'profile.relationshipStatus': _relationshipStatusController.text.trim(),
        'profile.pets': _petsController.text.trim(),
        'profile.favoriteFood': _favoriteFoodController.text.trim(),
        'profile.ammoText': _ammoTextController.text.trim(),
      });
      if (mounted) setState(() => _statusMessage = 'Profile saved.');
    } catch (e) {
      if (mounted) setState(() => _statusMessage = 'Failed to save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addPhoto() async {
    // Read the service before any await - context.read after an async gap
    // risks using a BuildContext that's no longer valid if this State was
    // disposed while awaiting (e.g. user navigated away mid-upload).
    final moderationService = context.read<VisualModerationService>();
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null || !mounted) return;

    setState(() {
      _statusMessage = null;
      _saving = true;
    });

    final uid = FirebaseAuth.instance.currentUser!.uid;
    final storagePath = 'profile_photos/$uid/${DateTime.now().millisecondsSinceEpoch}.jpg';
    final storageRef = FirebaseStorage.instance.ref(storagePath);

    try {
      await storageRef.putFile(File(picked.path));

      final rejectionReason = await moderationService.checkImage(storagePath);
      if (rejectionReason != null) {
        await storageRef.delete();
        if (mounted) setState(() => _statusMessage = 'Photo rejected: $rejectionReason');
        return;
      }

      final downloadUrl = await storageRef.getDownloadURL();
      await _userRef.update({
        'profile.photoUrls': FieldValue.arrayUnion([downloadUrl]),
      });
      if (mounted) {
        setState(() {
          _photoUrls = [..._photoUrls, downloadUrl];
          _statusMessage = 'Photo added.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _statusMessage = 'Failed to add photo: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _removePhoto(String url) async {
    setState(() {
      _saving = true;
      _statusMessage = null;
    });
    try {
      await _userRef.update({
        'profile.photoUrls': FieldValue.arrayRemove([url]),
      });
      // Best-effort Storage cleanup - refFromURL works for Firebase
      // Storage download URLs. Not fatal if this fails (e.g. already
      // deleted); the Firestore removal above is the source of truth for
      // what's actually shown on the profile.
      try {
        await FirebaseStorage.instance.refFromURL(url).delete();
      } catch (_) {}
      if (mounted) setState(() => _photoUrls = _photoUrls.where((u) => u != url).toList());
    } catch (e) {
      if (mounted) setState(() => _statusMessage = 'Failed to remove photo: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _professionController.dispose();
    _educationController.dispose();
    _hometownController.dispose();
    _interestsController.dispose();
    _relationshipStatusController.dispose();
    _petsController.dispose();
    _favoriteFoodController.dispose();
    _ammoTextController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Cinematic backstage background (developer's art, 2026-09-14), same
    // pattern as the Ranks and My Battles screens: a transparent Scaffold
    // over a fixed image with a dark base and a light scrim, so the profile
    // form scrolls over the "House Lights Down" venue art. fitWidth +
    // topCenter keeps the neon graffiti / stage at the top uncropped; the
    // dark floor of the image sits behind the lower settings rows.
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Your Profile'),
        automaticallyImplyLeading: !widget.embedded,
      ),
      body: Stack(
        children: [
          const Positioned.fill(
            child: ColoredBox(color: Color(0xFF0E0B14)),
          ),
          Positioned.fill(
            child: Image.asset(
              'assets/home/profile_background.png',
              fit: BoxFit.fitWidth,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          // Light scrim for legibility. The form fields carry their own dark
          // fills, so this only has to lift white headings/labels off the
          // bright neon at the top and settle the lower rows into the dark
          // floor - a heavy scrim would wash out the art the developer chose.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x59000000),
                    Color(0x1F000000),
                    Color(0x73000000),
                  ],
                ),
              ),
            ),
          ),
          _loading
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      24,
                      kToolbarHeight + 8,
                      24,
                      24 + MediaQuery.of(context).padding.bottom,
                    ),
                    child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The player's actual username as a heading, read-only
                    // (developer's call, 2026-09-14): the top of a profile is
                    // your identity, not a prompt to rename yourself. The
                    // change-username control and the "your form" stats card
                    // that used to sit here are gone; the referral bits moved
                    // down near settings, where occasional actions belong.
                    _IdentityHeader(
                      username: _username,
                      rankTitle: _rankTitle,
                      photoUrl: _photoUrls.isNotEmpty ? _photoUrls.first : null,
                    ),
                    const SizedBox(height: 28),
                    // The mandatory intro video sits above photos because it
                    // is the one profile item a player CANNOT battle without
                    // (enforced in enterQueue), and it is the ammo the
                    // opponent actually studies pre-match.
                    const IntroVideoCard(),
                    const SizedBox(height: 24),
                    // States what is TRUE today rather than the eventual
                    // rule. Photos and manual approval are deliberately
                    // unenforced for the private beta, so a header reading
                    // "0/5, first must show your face" describes a
                    // requirement nothing checks - and a tester who
                    // believes it will think they cannot play until they
                    // have uploaded five.
                    Text(
                      'Photos',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Optional. Your first photo is the one other players see when they find you.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    _PhotoGrid(
                      photoUrls: _photoUrls,
                      busy: _saving,
                      onAdd: _addPhoto,
                      onRemove: _removePhoto,
                    ),
                    const SizedBox(height: 24),
                    Text('Required', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    _requiredField(_professionController, 'Profession'),
                    const SizedBox(height: 16),
                    _requiredField(_educationController, 'Education'),
                    const SizedBox(height: 16),
                    _requiredField(_hometownController, 'Hometown / location'),
                    const SizedBox(height: 16),
                    _requiredField(_interestsController, 'Interests'),
                    const SizedBox(height: 24),
                    Text('Optional', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    _optionalField(_relationshipStatusController, 'Relationship status'),
                    const SizedBox(height: 16),
                    _optionalField(_petsController, 'Pets'),
                    const SizedBox(height: 16),
                    _optionalField(_favoriteFoodController, 'Favorite food'),
                    const SizedBox(height: 16),
                    // Sat forty lines above this, directly under the
                    // invite card, where it read as a caption for
                    // inviting people. A label belongs next to the thing
                    // it labels.
                    Text(
                      'Give opponents some ammo - it\'s funnier if it\'s true.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _ammoTextController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Ammo (optional)',
                        hintText: 'Something embarrassing, or anything else you want opponents to have material on',
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_statusMessage != null) ...[
                      Text(_statusMessage!, style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 16),
                    ],
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save'),
                    ),
                    const SizedBox(height: 28),
                    const Divider(),
                    const SizedBox(height: 8),
                    // Referral bits live down here, not at the top - inviting a
                    // friend and recording who invited you are occasional
                    // actions, not what a player opens their profile to do.
                    const InviteCard(),
                    const ReferrerField(),
                    const SizedBox(height: 8),
                    const Divider(),
                    // Sits with the profile because being findable is a
                    // property of the profile, and it is the one control
                    // here that affects who can reach you rather than
                    // what they see.
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _directoryListed,
                      onChanged: _saving ? null : _setDirectoryListed,
                      title: const Text('Let people find me by name'),
                      subtitle: const Text(
                        'Subscribers can search for your username and see '
                        'your first photo and rank. Turn this off and you '
                        'stop appearing in search entirely.',
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.palette_outlined),
                      title: const Text('Appearance'),
                      subtitle:
                          const Text('Your skin - Card, and prestige unlocks.'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AppearanceScreen(),
                        ),
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.block),
                      title: const Text('Blocked players'),
                      subtitle: const Text('See and undo who you have blocked.'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const BlockedPlayersScreen(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 12),
                    // Sign out lives here now, off the Home app bar where a
                    // one-tap logout was too easy to hit by accident. A
                    // deliberate action in the account area, but plainly
                    // findable (unlike delete, which is quieter still).
                    OutlinedButton.icon(
                      onPressed: _signingOut ? null : _signOut,
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Sign out'),
                    ),
                    const SizedBox(height: 8),
                    // CCPA requires a user-facing way to delete an account
                    // and its data (see CLAUDE.md's Compliance / Account
                    // Management item). Placed here because this is where
                    // a user's personal data lives, and kept visually
                    // quiet - it should be findable, not easy to hit by
                    // accident. The screen itself explains exactly what is
                    // deleted and what is kept before anything happens.
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const DeleteAccountScreen()),
                      ),
                      child: const Text(
                        'Delete my account',
                        style: TextStyle(color: Color(0xFFE05252)),
                      ),
                    ),
                        ],
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  /// Drops this device's push token before signing out, so the next person
  /// to sign in here doesn't receive the previous account's match alerts.
  /// Best-effort: a failure to clean up the token must not trap someone in
  /// an account they're trying to leave, so sign-out proceeds regardless.
  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    final push = context.read<PushNotificationService>();
    final auth = context.read<AuthService>();
    try {
      await push.unregister();
    } catch (_) {
      // Intentionally ignored - see above.
    }
    await auth.signOut();
    // No setState after: signing out swaps this whole tree out via AuthGate.
  }

  Widget _requiredField(TextEditingController controller, String label) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(labelText: label),
      validator: (value) => (value == null || value.trim().isEmpty) ? '$label is required' : null,
    );
  }

  Widget _optionalField(TextEditingController controller, String label) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(labelText: label),
    );
  }
}

/// The read-only identity at the top of the profile: avatar, username and
/// rank title. The username is deliberately not editable here.
class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({this.username, this.rankTitle, this.photoUrl});

  final String? username;
  final String? rankTitle;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final name =
        (username != null && username!.isNotEmpty) ? username! : 'Your profile';
    return Column(
      children: [
        CircleAvatar(
          radius: 42,
          backgroundColor: scheme.surfaceContainerHighest,
          backgroundImage: photoUrl != null ? NetworkImage(photoUrl!) : null,
          child: photoUrl == null
              ? Icon(Icons.person, size: 44, color: scheme.onSurfaceVariant)
              : null,
        ),
        const SizedBox(height: 14),
        Text(
          name,
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        if (rankTitle != null && rankTitle!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            rankTitle!,
            style: text.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _PhotoGrid extends StatelessWidget {
  const _PhotoGrid({
    required this.photoUrls,
    required this.busy,
    required this.onAdd,
    required this.onRemove,
  });

  final List<String> photoUrls;
  final bool busy;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (var i = 0; i < photoUrls.length; i++) _photoTile(context, photoUrls[i]),
        if (photoUrls.length < kRequiredPhotoCount) _addTile(context),
      ],
    );
  }

  Widget _photoTile(BuildContext context, String url) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(url, width: 96, height: 96, fit: BoxFit.cover),
        ),
        Positioned(
          top: -8,
          right: -8,
          child: IconButton(
            icon: const Icon(Icons.cancel, size: 20),
            onPressed: busy ? null : () => onRemove(url),
          ),
        ),
      ],
    );
  }

  Widget _addTile(BuildContext context) {
    final isFacePhoto = photoUrls.isEmpty;
    return InkWell(
      onTap: busy ? null : onAdd,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.add_a_photo_outlined),
            if (isFacePhoto) ...[
              const SizedBox(height: 4),
              Text('Face', style: Theme.of(context).textTheme.labelSmall),
            ],
          ],
        ),
      ),
    );
  }
}
