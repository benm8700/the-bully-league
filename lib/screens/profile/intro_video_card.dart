import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/services/visual_moderation_service.dart';
import '../../widgets/looping_video.dart';

/// The MANDATORY 60-second "tell me about yourself" intro video (User
/// Profile System). This is the opponent's ammo, studied on a loop during
/// the pre-match reveal, and it is required before a player can battle
/// (enforced server-side in enterQueue - this card is how they satisfy it).
///
/// Chosen over a live pre-match video chat for cost and safety: a stored
/// file joins no Agora channel (no per-minute billing) and is screened
/// frame by frame at upload, before anyone sees it, rather than a live
/// stranger feed sampled every few seconds.
class IntroVideoCard extends StatefulWidget {
  const IntroVideoCard({super.key});

  @override
  State<IntroVideoCard> createState() => _IntroVideoCardState();
}

class _IntroVideoCardState extends State<IntroVideoCard> {
  String? _videoUrl;
  bool _loading = true;
  bool _busy = false;
  String? _status;

  DocumentReference<Map<String, dynamic>> get _userRef => FirebaseFirestore
      .instance
      .collection('users')
      .doc(FirebaseAuth.instance.currentUser!.uid);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final snap = await _userRef.get();
    final profile = snap.data()?['profile'] as Map<String, dynamic>? ?? {};
    if (mounted) {
      setState(() {
        _videoUrl = profile['introVideoUrl'] as String?;
        _loading = false;
      });
    }
  }

  Future<void> _record() async {
    // Read the service before the async gap, in case this State is disposed
    // while the camera is open.
    final moderation = context.read<VisualModerationService>();
    final picker = ImagePicker();
    final picked = await picker.pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(seconds: 60),
    );
    if (picked == null || !mounted) return;

    setState(() {
      _busy = true;
      _status = null;
    });

    final uid = FirebaseAuth.instance.currentUser!.uid;
    final path =
        'profile_videos/$uid/intro_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final ref = FirebaseStorage.instance.ref(path);

    try {
      await ref.putFile(
        File(picked.path),
        SettableMetadata(contentType: 'video/mp4'),
      );

      // Screened at upload: the URL is only written after approval, so its
      // presence IS the approved flag the battle gate reads.
      final rejection = await moderation.checkVideo(path);
      if (rejection != null) {
        await ref.delete();
        if (mounted) setState(() => _status = 'Video rejected: $rejection');
        return;
      }

      final url = await ref.getDownloadURL();
      final oldUrl = _videoUrl;
      await _userRef.set({
        'profile': {'introVideoUrl': url},
      }, SetOptions(merge: true));

      // Best-effort cleanup of the previous file so old intros do not pile
      // up in Storage. Never fatal - the profile field is the source of
      // truth for what actually plays.
      if (oldUrl != null && oldUrl.isNotEmpty) {
        try {
          await FirebaseStorage.instance.refFromURL(oldUrl).delete();
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _videoUrl = url;
          _status = 'Intro saved.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Could not save intro: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final hasVideo = _videoUrl != null && _videoUrl!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Intro video', style: text.titleMedium),
            const SizedBox(width: 8),
            if (!hasVideo)
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
          hasVideo
              ? 'Your 60-second "tell me about yourself". Opponents watch it '
                  'before your battle to find their angle.'
              : 'Record a 60-second "tell me about yourself". This is what '
                  'your opponent studies for ammo - you cannot battle without '
                  'it. Funnier if it is honest.',
          style: text.bodySmall,
        ),
        const SizedBox(height: 12),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (hasVideo)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: Align(
                  child: LoopingVideo(url: _videoUrl!, muted: true),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _record,
                icon: const Icon(Icons.videocam_outlined, size: 18),
                label: const Text('Re-record'),
              ),
            ],
          )
        else
          FilledButton.icon(
            onPressed: _busy ? null : _record,
            icon: const Icon(Icons.videocam, size: 18),
            label: const Text('Record intro (60s)'),
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
                Expanded(child: Text('Checking your video...')),
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
