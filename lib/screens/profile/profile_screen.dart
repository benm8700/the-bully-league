import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/services/visual_moderation_service.dart';

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
  const ProfileScreen({super.key});

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
  String? _statusMessage;
  List<String> _photoUrls = [];

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
    if (mounted) {
      setState(() {
        _photoUrls = photoUrls;
        _loading = false;
      });
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
    return Scaffold(
      appBar: AppBar(title: const Text('Your Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Give opponents some ammo - it\'s funnier if it\'s true.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Photos (${_photoUrls.length}/$kRequiredPhotoCount, first must show your face)',
                      style: Theme.of(context).textTheme.titleMedium,
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
                  ],
                ),
              ),
            ),
    );
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
