import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Watching a live tournament battle you are not in.
///
/// WHY THIS IS ITS OWN INTERFACE rather than more methods on
/// VideoCallService. Spectating is the one part of this app whose backend
/// is genuinely expected to change: Agora bills per participant-minute, so
/// it is cheap at fifty viewers and expensive at five hundred, and the
/// long-term answer is a CDN (Cloudflare Stream or Mux) that bills per
/// delivered minute instead.
///
/// Agora was chosen for now because it needs no new vendor account, no
/// card and no API token before a single live event has ever run - the
/// friction of setting all that up was real and the saving was pennies on
/// events that do not exist yet. But that decision has an expiry date, so
/// the swap is made cheap in advance: this interface is what the UI talks
/// to, and moving to a CDN becomes one new implementation class rather
/// than a rewrite of every screen that shows a stream.
///
/// The same reasoning, and the same shape, as VideoCallService wrapping
/// Agora so the video provider can be replaced without touching the match
/// flow.
abstract class SpectatorService {
  /// Acquires whatever the implementation needs. Never asks for camera or
  /// microphone permission - a spectator only ever receives.
  Future<void> initialize();

  /// Joins a live battle as an audience member.
  ///
  /// [token] is a SUBSCRIBER credential minted by the server, which is
  /// what stops a spectator broadcasting into someone else's match. A CDN
  /// implementation would take a signed playback URL here instead; the
  /// caller does not need to know which.
  Future<void> watch({
    required String channelName,
    required String token,
    required int uid,
  });

  Future<void> stopWatching();

  Future<void> dispose();

  /// The two players' video, keyed by their fixed Agora uids (1 and 2).
  /// Null until that player's stream actually arrives, so the UI can show
  /// a placeholder for someone who has not turned their camera on yet.
  Widget? playerVideo(int playerUid);

  /// Rebuilds the UI as streams arrive and drop.
  ValueListenable<Set<int>> get presentUids;

  /// Whether the viewer is currently connected to the battle.
  ValueListenable<bool> get isWatching;

  /// A human-readable reason the stream is not playing, or null.
  ///
  /// EXISTS BECAUSE THE FAILURE IS OTHERWISE SILENT. Joining a channel
  /// succeeds locally and is then accepted or rejected asynchronously by
  /// the provider - so a bad or expired token leaves the screen sitting on
  /// "waiting for the battle" indefinitely, which is indistinguishable
  /// from two players who simply have not started yet. Found by watching
  /// exactly that screen during a device test and being unable to tell
  /// which of the two it was.
  ValueListenable<String?> get failure;
}
