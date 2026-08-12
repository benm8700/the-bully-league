/// Wraps whatever visual-moderation provider checks uploaded photos for
/// nudity/explicit content, per CLAUDE.md's Content Policy & Moderation
/// section - kept behind an interface (like VideoCallService) so the
/// provider (currently Google Cloud Vision SafeSearch) can be swapped
/// later without touching UI code.
///
/// Covers profile photos only (Build Order step 9a). Real-time moderation
/// during LIVE matches is a SEPARATE, currently-blocked problem - see
/// CLAUDE.md's step 9a status note for why (agora_rtc_engine 6.6.3's
/// registerVideoFrameObserver is an unimplemented stub, so there's no way
/// to read live video frames to moderate in the first place).
abstract class VisualModerationService {
  /// Returns null if the image at [storagePath] passes moderation, or a
  /// human-readable rejection reason if it doesn't.
  Future<String?> checkImage(String storagePath);
}
