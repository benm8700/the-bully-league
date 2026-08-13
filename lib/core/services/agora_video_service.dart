import 'dart:async';
import 'dart:convert';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../config/agora_config.dart';
import 'video_call_service.dart';

class AgoraVideoCallService implements VideoCallService {
  late final RtcEngine _engine;
  String? _channelName;
  int? _dataStreamId;
  Completer<void>? _joinCompleter;
  VideoFrameObserver? _frameObserver;
  DateTime? _lastFrameSampleTime;

  // Sampling, not per-frame - see the class doc comment on
  // remoteFrameSamples. Cloud Vision is billed per call and there's no
  // reason to check more often than this for a moderation use case (a
  // violation stays on-screen for well more than 4 seconds).
  static const _frameSampleInterval = Duration(seconds: 4);

  final ValueNotifier<int?> _remoteUid = ValueNotifier(null);
  final ValueNotifier<bool> _isJoined = ValueNotifier(false);
  final ValueNotifier<int> _localAudioLevel = ValueNotifier(0);
  final ValueNotifier<int?> _localUid = ValueNotifier(null);
  final StreamController<Map<String, dynamic>> _matchMessages =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<RawVideoFrame> _remoteFrameSamples =
      StreamController<RawVideoFrame>.broadcast();

  @override
  ValueListenable<int?> get remoteUid => _remoteUid;

  @override
  ValueListenable<bool> get isJoined => _isJoined;

  @override
  ValueListenable<int> get localAudioLevel => _localAudioLevel;

  @override
  ValueListenable<int?> get localUid => _localUid;

  @override
  Stream<Map<String, dynamic>> get matchMessages => _matchMessages.stream;

  @override
  Stream<RawVideoFrame> get remoteFrameSamples => _remoteFrameSamples.stream;

  @override
  Future<void> initialize() async {
    _engine = createAgoraRtcEngine();
    await _engine.initialize(const RtcEngineContext(appId: agoraAppId));
    await _engine.enableVideo();
    await _engine.startPreview();
    // Volume indication only reports once a user is publishing in a
    // channel (see localAudioLevel doc comment) - enabling here just
    // arms it for whenever joinChannel happens.
    await _engine.enableAudioVolumeIndication(interval: 200, smooth: 3, reportVad: true);

    // Must be registered before joinChannel per Agora's docs. Despite
    // earlier CLAUDE.md notes claiming this API is an unimplemented stub,
    // it's confirmed live to deliver real frame data - getMediaEngine()
    // returns a hand-written override with a working native-backed
    // implementation, not the auto-generated binding stub that actually
    // does throw UnimplementedError. See CLAUDE.md's step 3/9a status
    // notes for the full story.
    _frameObserver = VideoFrameObserver(
      onRenderVideoFrame: (channelId, remoteUid, videoFrame) {
        final now = DateTime.now();
        if (_lastFrameSampleTime != null &&
            now.difference(_lastFrameSampleTime!) < _frameSampleInterval) {
          return;
        }
        final width = videoFrame.width;
        final height = videoFrame.height;
        final yBuffer = videoFrame.yBuffer;
        final uBuffer = videoFrame.uBuffer;
        final vBuffer = videoFrame.vBuffer;
        if (width == null || height == null || yBuffer == null || uBuffer == null || vBuffer == null) {
          return;
        }
        _lastFrameSampleTime = now;
        _remoteFrameSamples.add(RawVideoFrame(
          remoteUid: remoteUid,
          width: width,
          height: height,
          yStride: videoFrame.yStride ?? width,
          uStride: videoFrame.uStride ?? (width ~/ 2),
          vStride: videoFrame.vStride ?? (width ~/ 2),
          yBuffer: yBuffer,
          uBuffer: uBuffer,
          vBuffer: vBuffer,
        ));
      },
    );
    _engine.getMediaEngine().registerVideoFrameObserver(_frameObserver!);

    _engine.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (connection, elapsed) async {
          _isJoined.value = true;
          _localUid.value = connection.localUid;
          try {
            _dataStreamId = await _engine.createDataStream(
              const DataStreamConfig(syncWithAudio: false, ordered: true),
            );
          } catch (e) {
            debugPrint('Agora createDataStream failed: $e');
          }
          // Only now is it safe for joinChannel()'s caller to proceed -
          // see the Completer note on joinChannel below.
          _joinCompleter?.complete();
        },
        onUserJoined: (connection, remoteUid, elapsed) => _remoteUid.value = remoteUid,
        onUserOffline: (connection, remoteUid, reason) => _remoteUid.value = null,
        onLeaveChannel: (connection, stats) {
          _isJoined.value = false;
          _remoteUid.value = null;
          _localUid.value = null;
          _dataStreamId = null;
        },
        onAudioVolumeIndication: (connection, speakers, speakerNumber, totalVolume) {
          final local = speakers.where((s) => s.uid == 0);
          if (local.isNotEmpty) {
            _localAudioLevel.value = local.first.volume ?? 0;
          }
        },
        onStreamMessage: (connection, remoteUid, streamId, data, length, sentTs) {
          try {
            final decoded = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
            _matchMessages.add(decoded);
          } catch (e) {
            debugPrint('Agora onStreamMessage decode failed: $e');
          }
        },
        onError: (err, msg) => debugPrint('Agora error: $err $msg'),
        onConnectionStateChanged: (connection, state, reason) =>
            debugPrint('Agora connection state: $state, reason: $reason'),
      ),
    );
  }

  @override
  Future<void> joinChannel({required String channelName, required int uid, String token = ''}) async {
    _channelName = channelName;
    // await _engine.joinChannel(...) resolves once the join REQUEST is
    // accepted, not once the join actually completes - the real signal is
    // the separate onJoinChannelSuccess event, which is also when it's
    // finally safe to call createDataStream. Without waiting for that
    // event here, callers (e.g. MatchScreen's opponent-identity exchange)
    // that call sendMatchMessage as soon as joinChannel's Future resolves
    // could do so before _dataStreamId was ever set, silently dropping the
    // message (sendMatchMessage no-ops if _dataStreamId is null). Confirmed
    // live: this caused the identity exchange to randomly fail, breaking
    // match doc creation ("missing player identity").
    _joinCompleter = Completer<void>();
    await _engine.joinChannel(
      token: token,
      channelId: channelName,
      uid: uid,
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ),
    );
    await _joinCompleter!.future;
  }

  @override
  Future<void> leaveChannel() async {
    await _engine.leaveChannel();
    _channelName = null;
  }

  @override
  Future<void> muteLocalAudio(bool muted) => _engine.muteLocalAudioStream(muted);

  @override
  Future<void> sendMatchMessage(Map<String, dynamic> data) async {
    final streamId = _dataStreamId;
    if (streamId == null) return;
    await _engine.sendStreamMessage(
      streamId: streamId,
      data: Uint8List.fromList(utf8.encode(jsonEncode(data))),
      length: utf8.encode(jsonEncode(data)).length,
    );
  }

  @override
  Widget localVideoView() {
    return AgoraVideoView(
      controller: VideoViewController(
        rtcEngine: _engine,
        canvas: const VideoCanvas(uid: 0),
      ),
    );
  }

  @override
  Widget? remoteVideoView() {
    final uid = _remoteUid.value;
    final channelName = _channelName;
    if (uid == null || channelName == null) return null;

    return AgoraVideoView(
      controller: VideoViewController.remote(
        rtcEngine: _engine,
        canvas: VideoCanvas(uid: uid),
        connection: RtcConnection(channelId: channelName),
      ),
    );
  }

  @override
  Future<void> dispose() async {
    // Must leave the channel before releasing the engine - otherwise the
    // server can briefly still consider this uid joined, and a new engine
    // instance rejoining the same channel moments later (e.g. navigating
    // PreMatchScreen -> MatchScreen) can get rejected with
    // AgoraRtcException(-17, ERR_JOIN_CHANNEL_REJECTED).
    if (_isJoined.value) {
      try {
        await _engine.leaveChannel();
      } catch (_) {
        // Best-effort - still proceed to release the engine below.
      }
    }
    final observer = _frameObserver;
    if (observer != null) {
      try {
        _engine.getMediaEngine().unregisterVideoFrameObserver(observer);
      } catch (_) {
        // Best-effort - still proceed to release the engine below.
      }
    }
    _remoteUid.dispose();
    _isJoined.dispose();
    _localAudioLevel.dispose();
    _localUid.dispose();
    await _matchMessages.close();
    await _remoteFrameSamples.close();
    await _engine.release();
  }
}
