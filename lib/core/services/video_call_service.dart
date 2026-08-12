import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Wraps the video call provider (Agora) so UI/match-flow code never talks
/// to the SDK directly - see CLAUDE.md's "Video provider logic MUST be
/// isolated" rule. Swapping providers later means writing a new
/// implementation of this interface, not touching call sites.
abstract class VideoCallService {
  /// Must be called once, before joinChannel, to acquire camera/mic and
  /// initialize the underlying engine.
  Future<void> initialize();

  Future<void> joinChannel({required String channelName, required int uid, String token = ''});

  Future<void> leaveChannel();

  Future<void> dispose();

  /// Renders this device's own camera preview.
  Widget localVideoView();

  /// Renders the remote participant's video once they've joined. Returns
  /// null until a remote user is present in the channel.
  Widget? remoteVideoView();

  /// Notifies the UI when a remote user joins/leaves so it can rebuild
  /// (e.g. to show/hide the remote video view).
  ValueListenable<int?> get remoteUid;

  ValueListenable<bool> get isJoined;

  /// Local mic volume, range [0,255]. Only reports real values once joined
  /// to a channel (Agora only emits volume indication for a publishing
  /// user) - see CLAUDE.md's Agora notes on this. Used for the pre-match
  /// mic check (Build Order step 3), not a general-purpose meter.
  ValueListenable<int> get localAudioLevel;

  /// This device's own uid as assigned by the provider on join. Null until
  /// onJoinChannelSuccess fires. Used by MatchScreen for host election
  /// (see Build Order step 4 match flow notes in CLAUDE.md).
  ValueListenable<int?> get localUid;

  Future<void> muteLocalAudio(bool muted);

  /// Sends a small JSON-encodable state message to the other participant
  /// over the provider's low-latency data channel - used to synchronize
  /// round/turn/timer state between the two devices (no backend match
  /// document exists yet to do this via Firestore).
  Future<void> sendMatchMessage(Map<String, dynamic> data);

  /// Decoded messages sent by the other participant via sendMatchMessage.
  Stream<Map<String, dynamic>> get matchMessages;
}
