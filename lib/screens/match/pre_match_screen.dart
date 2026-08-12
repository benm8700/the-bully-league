import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/config/agora_config.dart';
import '../../core/services/agora_video_service.dart';
import '../../core/services/video_call_service.dart';
import 'match_screen.dart';

/// Camera/mic check before a match (Build Order step 3). Real per-check
/// scope, per CLAUDE.md's Agora notes:
/// - Mic level: REAL, via Agora's volume indication.
/// - Lighting/shake/face-visible: advisory prompts only - the Agora Flutter
///   SDK's video frame observer (needed for real brightness/motion/face
///   analysis) is an unimplemented stub in agora_rtc_engine 6.6.3
///   (throws UnimplementedError - see registerVideoFrameObserver in the
///   package source). Revisit if a future SDK version implements it, or
///   integrate ML Kit separately for face detection.
///
/// TEMPORARY: joins "test-channel" with the hardcoded temp token (same as
/// CallTestScreen) purely so Agora's volume indication has a channel to
/// report from - real matchmaking will assign a real channel+token here
/// once it exists (Build Order step 4+).
class PreMatchScreen extends StatefulWidget {
  const PreMatchScreen({super.key});

  @override
  State<PreMatchScreen> createState() => _PreMatchScreenState();
}

class _PreMatchScreenState extends State<PreMatchScreen> {
  late final VideoCallService _videoCallService;
  bool _initialized = false;
  bool _micVerified = false;
  bool _serviceDisposed = false;
  bool _navigating = false;
  String? _error;

  static const _micThreshold = 15; // out of 255

  @override
  void initState() {
    super.initState();
    _videoCallService = AgoraVideoCallService();
    _setup();
  }

  Future<void> _setup() async {
    try {
      await _videoCallService.initialize();
      await _videoCallService.joinChannel(
        channelName: 'test-channel',
        uid: 0,
        token: agoraTestChannelToken,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Camera/mic setup failed: $e');
      return;
    }
    if (!mounted) return;
    setState(() => _initialized = true);
    _videoCallService.localAudioLevel.addListener(_onAudioLevel);
  }

  void _onAudioLevel() {
    if (_micVerified) return;
    if (_videoCallService.localAudioLevel.value >= _micThreshold) {
      setState(() => _micVerified = true);
    }
  }

  @override
  void dispose() {
    _videoCallService.localAudioLevel.removeListener(_onAudioLevel);
    // Only dispose here if _onReady() didn't already do it - see there for
    // why: State.dispose() can't be async/awaited, so relying on it to
    // leave the channel before MatchScreen's own engine tries to join the
    // same channel is a race (MatchScreen usually wins, and Agora rejects
    // the join with AgoraRtcException(-17) since this engine is still
    // joined).
    if (!_serviceDisposed) {
      _videoCallService.dispose();
    }
    super.dispose();
  }

  Future<void> _onReady() async {
    if (_navigating) return;
    setState(() => _navigating = true);
    _videoCallService.localAudioLevel.removeListener(_onAudioLevel);
    _serviceDisposed = true;
    await _videoCallService.dispose();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MatchScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pre-Match Check')),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : !_initialized
              ? const Center(child: CircularProgressIndicator())
              : _buildCheckUi(),
    );
  }

  Widget _buildCheckUi() {
    return Column(
      children: [
        Expanded(
          flex: 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _videoCallService.localVideoView(),
              const CustomPaint(painter: _FramingGuidePainter(), child: SizedBox.expand()),
            ],
          ),
        ),
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildMicMeter(),
                const SizedBox(height: 16),
                const _AdvisoryPrompt(
                  icon: Icons.wb_sunny_outlined,
                  text: 'Make sure you\'re in a well-lit area.',
                ),
                const _AdvisoryPrompt(
                  icon: Icons.videocam_outlined,
                  text: 'Hold your device steady.',
                ),
                const _AdvisoryPrompt(
                  icon: Icons.face_outlined,
                  text: 'Keep your face inside the outline.',
                ),
                const Spacer(),
                FilledButton(
                  onPressed: (_micVerified && !_navigating) ? _onReady : null,
                  child: _navigating
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_micVerified ? "I'm Ready" : 'Say something to test your mic...'),
                ),
                if (kDebugMode && !_micVerified)
                  TextButton(
                    onPressed: _navigating ? null : _onReady,
                    child: const Text('Skip mic check (debug build only)'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMicMeter() {
    return ValueListenableBuilder<int>(
      valueListenable: _videoCallService.localAudioLevel,
      builder: (context, level, _) {
        final fraction = (level / 255).clamp(0.0, 1.0);
        return Row(
          children: [
            Icon(
              _micVerified ? Icons.mic : Icons.mic_none,
              color: _micVerified ? Colors.green : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 8,
                  color: _micVerified ? Colors.green : Colors.amber,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AdvisoryPrompt extends StatelessWidget {
  const _AdvisoryPrompt({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _FramingGuidePainter extends CustomPainter {
  const _FramingGuidePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final center = Offset(size.width / 2, size.height * 0.42);
    final rect = Rect.fromCenter(center: center, width: size.width * 0.55, height: size.height * 0.6);
    canvas.drawOval(rect, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
