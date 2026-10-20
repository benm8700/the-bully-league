import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../match/pre_match_screen.dart';

/// Where an SMS invite points. Placeholder until a real store listing exists
/// (same as the website's download CTA); swap when the app ships.
const String _appDownloadUrl = 'https://the-bully-league.vercel.app';

/// In-session cache of the recent-challenge chips, so re-opening the screen
/// shows them INSTANTLY rather than waiting on the callable each time. The
/// very first open of a session still fetches once; this is a cheap win with
/// no new storage dependency (persisting across launches would need one).
List<Map<String, dynamic>> _cachedRecentTargets = const [];

/// Challenge someone by name, and answer challenges sent to you.
///
/// THIS IS THE ONLY PATH THAT WORKS WITH FIVE USERS. Every other way into
/// a match needs a stranger to be awake and in the app at the same moment,
/// which is exactly what a private beta cannot supply. The beta group is a
/// handful of friends - the people who most want to battle each other on
/// purpose.
///
/// BY USERNAME, NOT THROUGH THE DIRECTORY, and that is what keeps this
/// free at every tier: the searchable player directory is a subscriber
/// feature, but knowing your friend's name is not. CLAUDE.md is explicit
/// that friend battles must not be paywalled.
class ChallengeScreen extends StatefulWidget {
  const ChallengeScreen({super.key});

  @override
  State<ChallengeScreen> createState() => _ChallengeScreenState();
}

class _ChallengeScreenState extends State<ChallengeScreen> {
  final _controller = TextEditingController();
  List<Map<String, dynamic>> _incoming = const [];
  List<Map<String, dynamic>> _outgoing = const [];
  List<Map<String, dynamic>> _accepted = const [];
  List<Map<String, dynamic>> _recent = _cachedRecentTargets;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _sent;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _loadRecent();
    // Poll so the challenger learns their challenge was accepted WITHOUT
    // reloading the screen. Accepting is server-side and instant on the
    // target's device; without this, the challenger's "Waiting on X" just
    // sits there while the match they can join already exists. Cheap - one
    // callable every few seconds, and only while this short-lived screen is
    // open (the timer is cancelled on dispose).
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('getMyChallenges')
          .call<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _incoming = ((r.data['incoming'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _outgoing = ((r.data['outgoing'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _accepted = ((r.data['accepted'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadRecent() async {
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('getRecentChallengeTargets')
          .call<Map<String, dynamic>>();
      final recent = ((r.data['recent'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      _cachedRecentTargets = recent; // instant on the next open
      if (!mounted) return;
      setState(() => _recent = recent);
    } catch (_) {/* no recents, no chips */}
  }

  Future<void> _send() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;
    // Phone vs username: a value that's (almost) all phone characters with
    // enough digits is treated as a number; anything else is a username.
    final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
    final looksPhone =
        digits.length >= 7 && RegExp(r'^[+0-9 ()\-.]+$').hasMatch(input);
    setState(() {
      _busy = true;
      _error = null;
      _sent = null;
    });
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('challengeFriend')
          .call<Map<String, dynamic>>(
              looksPhone ? {'phone': input} : {'username': input});
      if (!mounted) return;
      // No account on that number yet - fire an SMS invite; the challenge is
      // stashed and auto-delivered when they sign up with that number.
      if (r.data['needsInvite'] == true) {
        await _inviteBySms(
            r.data['phone'] as String? ?? input,
            r.data['fromUsername'] as String?);
        if (!mounted) return;
        _controller.clear();
        setState(() {
          _busy = false;
          _sent = "No account on that number yet - we opened a text invite. "
              "When they join, your challenge is waiting.";
        });
        return;
      }
      _controller.clear();
      setState(() {
        _busy = false;
        _sent = 'Challenge sent. They have an hour to answer.';
      });
      _confirm('Challenge sent!');
      await _load();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      // The server's message is shown verbatim: it knows whether this was an
      // unknown name, a block, or the outstanding cap, and it phrases a block
      // indistinguishably from a missing player on purpose.
      setState(() {
        _busy = false;
        _error = e.message ?? 'Could not send that.';
      });
    }
  }

  /// A clear, moving confirmation that the send actually happened - the quiet
  /// bottom-of-screen text was too easy to miss.
  void _confirm(String message) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        backgroundColor: scheme.primary,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
                child: Text(message,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold))),
          ],
        ),
      ));
  }

  /// Re-challenge a recent opponent by uid - one tap, no typing.
  Future<void> _sendToUid(String uid, String username) async {
    setState(() {
      _busy = true;
      _error = null;
      _sent = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('challengeFriend')
          .call<Map<String, dynamic>>({'toUid': uid});
      if (!mounted) return;
      setState(() {
        _busy = false;
        _sent = 'Challenge sent to $username.';
      });
      _confirm('Challenge sent to $username!');
      await _load();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? 'Could not send that.';
      });
    }
  }

  /// Opens the phone's own SMS app pre-filled with an invite + download link.
  Future<void> _inviteBySms(String phone, String? fromUsername) async {
    final who = (fromUsername != null && fromUsername.isNotEmpty)
        ? fromUsername
        : 'A friend';
    final body = '$who challenged you to a roast battle on The Bully League! '
        'Download and your challenge will be waiting: $_appDownloadUrl';
    // iOS (the real release platform) and Android disagree on how a prefilled
    // body is attached to an sms: link: iOS/iMessage expects it after a `&`
    // (sms:<number>&body=...), Android after a `?` (sms:<number>?body=...).
    // Uri(queryParameters:) always emits `?`, which iOS silently drops - the
    // Messages app opens with no text. Build the URI string by platform so the
    // invite is prefilled on both. (We're testing on Android; this is so the
    // iOS build Just Works when it ships.)
    final sep = defaultTargetPlatform == TargetPlatform.iOS ? '&' : '?';
    final uri = Uri.parse(
        'sms:${Uri.encodeComponent(phone)}${sep}body=${Uri.encodeComponent(body)}');
    try {
      final ok = await launchUrl(uri);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open your messages app.")),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open your messages app.")),
        );
      }
    }
  }

  Future<void> _respond(String challengeId, bool accept) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('respondToChallenge')
          .call<Map<String, dynamic>>({
        'challengeId': challengeId,
        'accept': accept,
      });
      if (!mounted) return;
      setState(() => _busy = false);
      if (accept && r.data['matchId'] != null) {
        await startChallengeMatch(context, r.data['matchId'] as String);
      } else {
        await _load();
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? 'Could not answer that.';
      });
    }
  }

  /// Takes the CHALLENGER into the match their opponent just accepted.
  /// Polling is paused for the duration so it does not fire uselessly under
  /// the match route, and resumed on return in case another is waiting.
  Future<void> _startAccepted(String matchId) async {
    _poll?.cancel();
    await startChallengeMatch(context, matchId);
    if (!mounted) return;
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _load();
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Challenge a friend')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                // The challenger's way in once their challenge is accepted.
                // Placed first because it is the most time-sensitive thing
                // on the screen - a "battle now" invitation that was just
                // taken up.
                if (_accepted.isNotEmpty) ...[
                  Text('Ready to battle', style: text.titleMedium),
                  const SizedBox(height: 8),
                  ..._accepted.map((c) => Card(
                        color: scheme.surfaceContainerHigh,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.sports_mma,
                                      size: 18, color: scheme.primary),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                        '${c['toUsername']} accepted your challenge',
                                        style: text.titleSmall),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              // The hottest action on the screen - your friend
                              // is ready NOW - so it is the one solid-pink CTA.
                              FilledButton(
                                onPressed: _busy
                                    ? null
                                    : () => _startAccepted(
                                        c['matchId'] as String),
                                child: const Text('Battle now'),
                              ),
                            ],
                          ),
                        ),
                      )),
                  const SizedBox(height: 24),
                ],
                if (_incoming.isNotEmpty) ...[
                  Text('Waiting for you', style: text.titleMedium),
                  const SizedBox(height: 8),
                  ..._incoming.map((c) => Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('${c['fromUsername']} challenged you',
                                  style: text.titleSmall),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    // Pink (the brand primary) - the green read
                                    // as out of place here (developer's call).
                                    child: FilledButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _respond(
                                              c['challengeId'] as String, true),
                                      child: const Text('Accept'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _respond(
                                            c['challengeId'] as String, false),
                                    child: const Text('No thanks'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      )),
                  const SizedBox(height: 24),
                ],
                Text('Challenge someone', style: text.titleMedium),
                const SizedBox(height: 4),
                Text(
                  // Friend battles are a PRIVATE scrimmage: it does not count,
                  // and it is NOT recorded, judged, or clipped - just you two.
                  'Enter their username or phone number. A number that has no '
                  'account yet gets a text invite - and your challenge is '
                  'waiting when they join. Private, just for fun: it does not '
                  'affect your rank and is never recorded or judged.',
                  style: text.bodySmall,
                ),
                const SizedBox(height: 12),
                // Recent opponents - tap to re-challenge without retyping.
                if (_recent.isNotEmpty) ...[
                  Text('Recent', style: text.labelMedium),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: _recent
                        .map((p) => ActionChip(
                              avatar: const Icon(Icons.replay, size: 16),
                              label: Text(p['username'] as String? ?? 'Player'),
                              onPressed: _busy
                                  ? null
                                  : () => _sendToUid(p['uid'] as String,
                                      p['username'] as String? ?? 'them'),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    labelText: 'Username or phone number',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _send(),
                ),
                const SizedBox(height: 12),
                // Purple compose action - initiating a challenge is calmer
                // than answering a live one, and the colour keeps it clearly
                // apart from the pink/green "a battle is happening" buttons.
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.secondary,
                    foregroundColor: scheme.onSecondary,
                  ),
                  onPressed: _busy ? null : _send,
                  child: const Text('Send challenge'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: text.bodySmall
                          ?.copyWith(color: Theme.of(context).colorScheme.error)),
                ],
                if (_sent != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: scheme.primary.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle, color: scheme.primary, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(_sent!,
                                style: text.bodyMedium
                                    ?.copyWith(color: scheme.primary))),
                      ],
                    ),
                  ),
                ],
                if (_outgoing.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text('Sent', style: text.titleMedium),
                  const SizedBox(height: 8),
                  ..._outgoing.map((c) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.hourglass_empty, size: 18),
                        title: Text('Waiting on ${c['toUsername']}'),
                      )),
                ],
              ],
            ),
    );
  }
}

/// Takes an accepted challenge straight into the camera check + battle.
///
/// NO recording-consent step: friend battles are PRIVATE now (not recorded,
/// judged or clipped - see RECORDED_MODES), so there is nothing to consent to,
/// and dropping it also removes the extra screen people were backing out of.
Future<void> startChallengeMatch(BuildContext context, String matchId) async {
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PreMatchScreen(mode: 'friend', challengeMatchId: matchId),
    ),
  );
}
