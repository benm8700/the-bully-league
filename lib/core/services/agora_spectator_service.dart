import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../config/agora_config.dart';
import 'spectator_service.dart';

/// Agora implementation of [SpectatorService].
///
/// JOINS AS AN AUDIENCE MEMBER, NOT A BROADCASTER, and that distinction is
/// the whole safety story. The client sets the audience role and the
/// server mints a SUBSCRIBER token; either alone would be enough to stop a
/// spectator publishing into somebody else's bracket match, and having
/// both means a modified client still cannot do it, because the token is
/// what Agora actually enforces.
///
/// COST NOTE, because it is the reason this class is expected to be
/// replaced: Agora bills every participant in a channel, audience
/// included. A thirty-minute tournament with fifty viewers is a few
/// dollars; five hundred viewers is roughly ten times that. When that
/// starts mattering, the fix is a new SpectatorService implementation
/// backed by a CDN - not changes here or in any screen.
class AgoraSpectatorService implements SpectatorService {
  RtcEngine? _engine;

  final _present = ValueNotifier<Set<int>>({});
  final _watching = ValueNotifier<bool>(false);

  @override
  ValueListenable<Set<int>> get presentUids => _present;

  @override
  ValueListenable<bool> get isWatching => _watching;

  @override
  Future<void> initialize() async {
    if (_engine != null) return;
    final engine = createAgoraRtcEngine();
    await engine.initialize(const RtcEngineContext(appId: agoraAppId));

    // Audience, set before joining. A spectator has no camera or
    // microphone in the channel at all, so nothing is captured and no
    // permission is ever requested.
    await engine.setClientRole(role: ClientRoleType.clientRoleAudience);
    await engine.enableVideo();

    engine.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (connection, elapsed) {
        _watching.value = true;
      },
      onUserJoined: (connection, remoteUid, elapsed) {
        _present.value = {..._present.value, remoteUid};
      },
      onUserOffline: (connection, remoteUid, reason) {
        _present.value = {..._present.value}..remove(remoteUid);
      },
      onLeaveChannel: (connection, stats) {
        _watching.value = false;
        _present.value = {};
      },
    ));
    _engine = engine;
  }

  @override
  Future<void> watch({
    required String channelName,
    required String token,
    required int uid,
  }) async {
    final engine = _engine;
    if (engine == null) {
      throw StateError('initialize() must be called before watch()');
    }
    await engine.joinChannel(
      token: token,
      channelId: channelName,
      uid: uid,
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleAudience,
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
        // Explicitly publish nothing. Belt and braces alongside the
        // audience role and the subscriber token.
        publishCameraTrack: false,
        publishMicrophoneTrack: false,
        autoSubscribeVideo: true,
        autoSubscribeAudio: true,
      ),
    );
  }

  @override
  Future<void> stopWatching() async {
    await _engine?.leaveChannel();
    _watching.value = false;
    _present.value = {};
  }

  @override
  Future<void> dispose() async {
    // leaveChannel before release, in that order. Releasing an engine
    // still in a channel is the race that produced
    // ERR_JOIN_CHANNEL_REJECTED elsewhere in this app.
    await stopWatching();
    await _engine?.release();
    _engine = null;
    _present.dispose();
    _watching.dispose();
  }

  @override
  Widget? playerVideo(int playerUid) {
    final engine = _engine;
    if (engine == null) return null;
    if (!_present.value.contains(playerUid)) return null;
    return AgoraVideoView(
      controller: VideoViewController.remote(
        rtcEngine: engine,
        canvas: VideoCanvas(uid: playerUid),
        connection: const RtcConnection(),
      ),
    );
  }
}
