import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Editable profile fields per CLAUDE.md's User Profile System - the
/// "ammo" a roaster gives opponents instead of relying purely on
/// appearance-based improv. Photos (5 required, face photo required,
/// visual-moderation gate) are explicitly deferred to Build Order step
/// 9a and NOT part of this screen - see CLAUDE.md's step 7 status note.
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
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _statusMessage = null;
    });
    try {
      // Photo fields (photoUrls, approvalStatus) intentionally omitted -
      // see the class doc comment. Firestore rules only pin rating/
      // rankTitle/rankedMatchesPlayed/wins/losses, so this update is
      // otherwise unrestricted for the owning user.
      await _userRef.update({
        'profile': {
          'profession': _professionController.text.trim(),
          'education': _educationController.text.trim(),
          'hometown': _hometownController.text.trim(),
          'interests': _interestsController.text.trim(),
          'relationshipStatus': _relationshipStatusController.text.trim(),
          'pets': _petsController.text.trim(),
          'favoriteFood': _favoriteFoodController.text.trim(),
          'ammoText': _ammoTextController.text.trim(),
        },
      });
      if (mounted) setState(() => _statusMessage = 'Profile saved.');
    } catch (e) {
      if (mounted) setState(() => _statusMessage = 'Failed to save: $e');
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
