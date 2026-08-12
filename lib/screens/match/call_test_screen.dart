import 'package:flutter/material.dart';

import '../../core/config/agora_config.dart';
import '../../core/services/agora_video_service.dart';
import '../../core/services/video_call_service.dart';

/// Bare-bones screen for proving the Agora 1:1 connection works end to end
/// (Build Order step 2) before any match UI/timers/mic-muting is built on
/// top of it. Not the final pre-match/match screen.
///
/// Runtime camera/mic permission requesting (normally via permission_handler)
/// is deliberately NOT wired up here: permission_handler_android currently
/// hardcodes compileSdk 37, which this project's Android toolchain can't
/// build against (see AGP/Gradle version notes in android/settings.gradle.kts).
/// Manifest permissions are declared; for local testing, grant them via
/// `adb shell pm grant <package> android.permission.CAMERA` (and
/// RECORD_AUDIO) before launching. Proper in-app permission UX belongs to
/// Build Order step 3 (pre-match camera/mic checks) - revisit this then.
class CallTestScreen extends StatefulWidget {
  const CallTestScreen({super.key});

  @override
  State<CallTestScreen> createState() => _CallTestScreenState();
}

class _CallTestScreenState extends State<CallTestScreen> {
  final _channelController = TextEditingController(text: 'test-channel');
  late final VideoCallService _videoCallService;
  bool _initialized = false;
  String? _permissionError;

  @override
  void initState() {
    super.initState();
    _videoCallService = AgoraVideoCallService();
    _setup();
  }

  Future<void> _setup() async {
    try {
      await _videoCallService.initialize();
    } catch (e) {
      setState(() => _permissionError = 'Camera/mic permission or init error: $e');
      return;
    }
    if (!mounted) return;
    setState(() => _initialized = true);
  }

  @override
  void dispose() {
    _channelController.dispose();
    _videoCallService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Video Call Test')),
      body: _permissionError != null
          ? Center(child: Text(_permissionError!))
          : !_initialized
              ? const Center(child: CircularProgressIndicator())
              : _buildCallUi(),
    );
  }

  Widget _buildCallUi() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _channelController,
                  decoration: const InputDecoration(labelText: 'Channel name'),
                ),
              ),
              const SizedBox(width: 12),
              ValueListenableBuilder<bool>(
                valueListenable: _videoCallService.isJoined,
                builder: (context, isJoined, _) {
                  return FilledButton(
                    onPressed: () => isJoined ? _videoCallService.leaveChannel() : _join(),
                    child: Text(isJoined ? 'Leave' : 'Join'),
                  );
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: ValueListenableBuilder<int?>(
                  valueListenable: _videoCallService.remoteUid,
                  builder: (context, remoteUid, _) {
                    final remoteView = _videoCallService.remoteVideoView();
                    return remoteView ??
                        const ColoredBox(
                          color: Colors.black,
                          child: Center(
                            child: Text(
                              'Waiting for opponent to join...',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                        );
                  },
                ),
              ),
              Positioned(
                right: 16,
                bottom: 16,
                width: 120,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _videoCallService.localVideoView(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _join() async {
    final channelName = _channelController.text.trim();
    try {
      await _videoCallService.joinChannel(
        channelName: channelName,
        uid: 0,
        // TEMPORARY: only valid for "test-channel" - see agora_config.dart.
        token: channelName == 'test-channel' ? agoraTestChannelToken : '',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Join failed: $e')));
    }
  }
}
