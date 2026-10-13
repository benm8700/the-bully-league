import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../config/agora_config.dart';

/// Multi-party video for the Main Stage JUDGES' table.
///
/// A judge both PUBLISHES (camera on, seated at the table) AND sees the other
/// judges - so unlike the 2-person battle (AgoraVideoCallService, a single
/// remote) and the audience-only spectator (AgoraSpectatorService), this tracks
/// MANY remote uids and renders a view per uid, on a live-broadcasting channel
/// where broadcasters (the 5 judges) and audience (the crowd) coexist.
///
/// The CROWD watching the table does NOT use this - they reuse
/// AgoraSpectatorService (audience) on the same `judges_<matchId>` channel,
/// which is already multi-remote. This service is the judges' publishing side.
///
/// Encoder is deliberately small (360x640): five tiles on a phone never need
/// 720p each, and it keeps the per-participant bill and bandwidth down.
class PanelVideoService {
  RtcEngine? _engine;
  String? _channelName;

  final _present = ValueNotifier<Set<int>>({});
  final _joined = ValueNotifier<bool>(false);
  final _failure = ValueNotifier<String?>(null);

  /// Remote judge uids currently publishing (never includes the local judge).
  ValueListenable<Set<int>> get presentUids => _present;
  ValueListenable<bool> get joined => _joined;
  ValueListenable<String?> get failure => _failure;

  static const _encoder = VideoEncoderConfiguration(
    dimensions: VideoDimensions(width: 360, height: 640),
    frameRate: 15,
    bitrate: 0,
    orientationMode: OrientationMode.orientationModeFixedPortrait,
    degradationPreference: DegradationPreference.maintainBalanced,
  );

  Future<void> initialize() async {
    if (_engine != null) return;
    final engine = createAgoraRtcEngine();
    await engine.initialize(const RtcEngineContext(appId: agoraAppId));
    await engine.enableVideo();
    await engine.setVideoEncoderConfiguration(_encoder);
    await engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);
    await engine.startPreview();
    engine.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (connection, elapsed) {
        _joined.value = true;
        _failure.value = null;
      },
      onError: (err, msg) {
        if (err == ErrorCodeType.errInvalidToken ||
            err == ErrorCodeType.errTokenExpired) {
          _failure.value = 'The table connection expired. Reopen it.';
        } else if (!_joined.value) {
          _failure.value = 'Could not join the judges\' table.';
        }
      },
      onRequestToken: (connection) =>
          _failure.value = 'The table connection expired. Reopen it.',
      onUserJoined: (connection, remoteUid, elapsed) {
        _present.value = {..._present.value, remoteUid};
      },
      onUserOffline: (connection, remoteUid, reason) {
        _present.value = {..._present.value}..remove(remoteUid);
      },
      onLeaveChannel: (connection, stats) {
        _joined.value = false;
        _present.value = {};
      },
    ));
    _engine = engine;
  }

  /// Join the judges' table as a broadcaster (camera + mic on). [uid] is the
  /// judge's seat uid (JUDGE_SEAT_UID_BASE + seat index), so the crowd and the
  /// other judges render each seat at a stable position.
  Future<void> join({
    required String channelName,
    required String token,
    required int uid,
  }) async {
    final engine = _engine;
    if (engine == null) {
      throw StateError('initialize() must be called before join()');
    }
    _channelName = channelName;
    await engine.joinChannel(
      token: token,
      channelId: channelName,
      uid: uid,
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
        publishCameraTrack: true,
        publishMicrophoneTrack: true,
        autoSubscribeVideo: true,
        autoSubscribeAudio: true,
      ),
    );
  }

  Future<void> muteLocalAudio(bool muted) async =>
      _engine?.muteLocalAudioStream(muted);

  /// The local judge's own camera tile.
  Widget? localVideoView() {
    final engine = _engine;
    if (engine == null) return null;
    return AgoraVideoView(
      controller: VideoViewController(
        rtcEngine: engine,
        canvas: const VideoCanvas(uid: 0),
      ),
    );
  }

  /// Another judge's tile, by their seat uid. Null until they are publishing.
  Widget? remoteVideoView(int uid) {
    final engine = _engine;
    final channelName = _channelName;
    if (engine == null || channelName == null) return null;
    if (!_present.value.contains(uid)) return null;
    return AgoraVideoView(
      controller: VideoViewController.remote(
        rtcEngine: engine,
        canvas: VideoCanvas(uid: uid),
        connection: RtcConnection(channelId: channelName),
      ),
    );
  }

  Future<void> leave() async {
    await _engine?.leaveChannel();
    _channelName = null;
    _joined.value = false;
    _present.value = {};
  }

  Future<void> dispose() async {
    // leaveChannel before release, in that order - releasing an engine still in
    // a channel is the race that produced ERR_JOIN_CHANNEL_REJECTED elsewhere.
    await leave();
    await _engine?.release();
    _engine = null;
    _present.dispose();
    _joined.dispose();
    _failure.dispose();
  }
}
