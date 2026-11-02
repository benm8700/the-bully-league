import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/services/visual_moderation_service.dart';

/// The outcome of a selfie capture attempt.
typedef SelfieResult = ({bool ok, bool cancelled, String? reason});

/// The MANDATORY profile selfie (face photo). Required before battling - it
/// shows in the pre-match bio reveal + the player directory so an opponent sees
/// who they're facing. Captured in-app from the FRONT camera (a real selfie,
/// not a gallery upload), screened at upload for nudity AND a clear face, and
/// stored only after approval - its presence IS the approved flag the battle
/// gate reads (same pattern as the intro video).
class SelfieCard extends StatefulWidget {
  const SelfieCard({super.key});

  /// Opens the front camera, uploads + moderates the selfie, and on approval
  /// writes profile.facePhotoUrl (and profile.photoUrls so existing avatars
  /// light up). Shows no UI beyond the camera; the caller shows progress/status.
  static Future<SelfieResult> capture(BuildContext context) async {
    // Read the service before the async gap, in case the State is disposed
    // while the camera is open.
    final moderation = context.read<VisualModerationService>();
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.front,
      maxWidth: 1080,
      maxHeight: 1080,
      imageQuality: 88,
    );
    if (picked == null) return (ok: false, cancelled: true, reason: null);

    final uid = FirebaseAuth.instance.currentUser!.uid;
    final path =
        'profile_photos/$uid/face_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final ref = FirebaseStorage.instance.ref(path);
    try {
      await ref.putFile(
        File(picked.path),
        SettableMetadata(contentType: 'image/jpeg'),
      );
      // Screened at upload (nudity + a clear face). The URL is only written
      // after approval, so its presence IS the approved flag the gate reads.
      final rejection = await moderation.checkFacePhoto(path);
      if (rejection != null) {
        try {
          await ref.delete();
        } catch (_) {}
        return (ok: false, cancelled: false, reason: rejection);
      }

      final url = await ref.getDownloadURL();
      final userRef =
          FirebaseFirestore.instance.collection('users').doc(uid);
      final oldUrl = ((await userRef.get()).data()?['profile']
          as Map<String, dynamic>?)?['facePhotoUrl'] as String?;
      // facePhotoUrl drives the battle gate; photoUrls keeps the existing
      // avatar/directory readers working with no change.
      await userRef.set({
        'profile': {
          'facePhotoUrl': url,
          'photoUrls': [url],
        },
      }, SetOptions(merge: true));

      // Best-effort cleanup of the previous selfie so they don't pile up.
      if (oldUrl != null && oldUrl.isNotEmpty) {
        try {
          await FirebaseStorage.instance.refFromURL(oldUrl).delete();
        } catch (_) {}
      }
      return (ok: true, cancelled: false, reason: null);
    } catch (e) {
      return (ok: false, cancelled: false, reason: 'Could not save selfie: $e');
    }
  }

  @override
  State<SelfieCard> createState() => _SelfieCardState();
}

class _SelfieCardState extends State<SelfieCard> {
  String? _photoUrl;
  bool _loading = true;
  bool _busy = false;
  String? _status;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  DocumentReference<Map<String, dynamic>> get _userRef => FirebaseFirestore
      .instance
      .collection('users')
      .doc(FirebaseAuth.instance.currentUser!.uid);

  @override
  void initState() {
    super.initState();
    _sub = _userRef.snapshots().listen((snap) {
      if (!mounted) return;
      final profile = snap.data()?['profile'] as Map<String, dynamic>? ?? {};
      setState(() {
        _photoUrl = profile['facePhotoUrl'] as String?;
        _loading = false;
      });
    }, onError: (_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _take() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    final result = await SelfieCard.capture(context);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) {
        _status = 'Selfie saved.';
      } else if (result.cancelled) {
        _status = null;
      } else {
        _status = result.reason;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final hasPhoto = _photoUrl != null && _photoUrl!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Profile selfie', style: text.titleMedium),
            const SizedBox(width: 8),
            if (!hasPhoto)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('Required',
                    style: text.labelSmall?.copyWith(color: scheme.primary)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          hasPhoto
              ? 'This is the face your opponent sees before a battle. Tap '
                  'Retake for a new one.'
              : 'Take a quick selfie. Your opponent sees who they\'re facing - '
                  'you cannot battle without it.',
          style: text.bodySmall,
        ),
        const SizedBox(height: 12),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (hasPhoto)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  _photoUrl!,
                  width: 110,
                  height: 110,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 110,
                    height: 110,
                    color: scheme.surfaceContainerHighest,
                    child: const Icon(Icons.person_outline),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _take,
                icon: const Icon(Icons.camera_alt_outlined, size: 18),
                label: const Text('Retake'),
              ),
            ],
          )
        else
          FilledButton.icon(
            onPressed: _busy ? null : _take,
            icon: const Icon(Icons.camera_alt, size: 18),
            label: const Text('Take selfie'),
          ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Row(
              children: [
                SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 12),
                Expanded(child: Text('Checking your selfie...')),
              ],
            ),
          ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_status!, style: text.bodySmall),
          ),
      ],
    );
  }
}
