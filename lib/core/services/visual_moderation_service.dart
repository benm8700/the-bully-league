import 'dart:typed_data';

/// Wraps whatever visual-moderation provider checks photos and video
/// frames for nudity/explicit content, per CLAUDE.md's Content Policy &
/// Moderation section - kept behind an interface (like VideoCallService)
/// so the provider (currently Google Cloud Vision SafeSearch) can be
/// swapped later without touching UI code.
abstract class VisualModerationService {
  /// Returns null if the image at [storagePath] passes moderation, or a
  /// human-readable rejection reason if it doesn't. Used for profile
  /// photos (Build Order step 9a), which are already-uploaded Storage
  /// objects.
  Future<String?> checkImage(String storagePath);

  /// Same as [checkImage], but for an image that only exists in memory -
  /// used for live match video frames (sampled from RawVideoFrame, see
  /// VideoCallService), which are never uploaded to Storage since they're
  /// ephemeral moderation checks, not content anyone needs to keep.
  Future<String?> checkImageBytes(Uint8List jpegBytes);
}
