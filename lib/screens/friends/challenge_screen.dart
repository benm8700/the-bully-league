import '../../widgets/incoming_challenge_card.dart';
import '../../widgets/neon_action_button.dart';
import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../widgets/expiry_countdown.dart';
import '../directory/player_search_screen.dart';
import '../match/pre_match_screen.dart';
import '../match/recording_consent_screen.dart';

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
  List<Map<String, dynamic>> _invites = const [];
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
        _invites = ((r.data['invites'] as List?) ?? const [])
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
    } catch (_) {
      /* no recents, no chips */
    }
  }

  Future<void> _send([TextEditingController? from]) async {
    final field = from ?? _controller;
    final input = field.text.trim();
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
            looksPhone
                ? {'phone': input}
                : input.contains('@')
                ? {'email': input}
                : {'username': input},
          );
      if (!mounted) return;
      // No account on that number yet - fire an SMS invite; the challenge is
      // stashed and auto-delivered when they sign up with that number.
      if (r.data['needsInvite'] == true) {
        await _inviteBySms(
          r.data['phone'] as String? ?? input,
          r.data['fromUsername'] as String?,
        );
        if (!mounted) return;
        field.clear();
        setState(() {
          _busy = false;
          _sent =
              "No account on that number yet - we opened a text invite. "
              "Hit Send in Messages. When they join, your challenge is "
              "waiting.";
        });
        await _load();
        return;
      }
      field.clear();
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
      ..showSnackBar(
        SnackBar(
          backgroundColor: scheme.primary,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
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
    final body =
        '$who challenged you to a roast battle on The Bully League! '
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
      'sms:${Uri.encodeComponent(phone)}${sep}body=${Uri.encodeComponent(body)}',
    );
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
      appBar: AppBar(
        title: const Text('Roast a friend'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Find a player',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlayerSearchScreen()),
            ),
          ),
        ],
      ),
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
                  ..._accepted.map(
                    (c) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: NeonAlertStrip(
                        pulse: true,
                        leading: const Icon(
                          Icons.sports_mma_rounded,
                          color: Color(0xFFFF2E7E),
                          size: 24,
                          shadows: [
                            Shadow(color: Color(0xFFFF2E7E), blurRadius: 10),
                          ],
                        ),
                        title: '${c['toUsername']} accepted your challenge',
                        subtitle: 'They are ready right now',
                        pillLabel: 'Battle now',
                        onTap: () {
                          if (!_busy) _startAccepted(c['matchId'] as String);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                if (_incoming.isNotEmpty) ...[
                  Text('Waiting for you', style: text.titleMedium),
                  const SizedBox(height: 8),
                  ..._incoming.map(
                    (c) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: IncomingChallengeCard(
                        fromUsername: '${c['fromUsername']}',
                        expiresAtMs: c['expiresAtMs'],
                        busy: _busy,
                        onAccept: () =>
                            _respond(c['challengeId'] as String, true),
                        onDecline: () =>
                            _respond(c['challengeId'] as String, false),
                        declineLabel: 'No thanks',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                // ONE BOX (2026-11-10): a phone number or a username. _send
                // tells them apart. A number on an account gets the challenge
                // in-app; a number with no account opens a text invite, and
                // the challenge waits for them when they sign up with it.
                Text('Who are you roasting?', style: text.titleMedium),
                const SizedBox(height: 4),
                Text(
                  "Enter a friend's phone number, username or email. If they "
                  "aren't on The Bully League yet, we'll text them a link to "
                  'join, and your challenge will be waiting. Strangers judge '
                  'it and tell you who won. It never touches your rank.',
                  style: text.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.send,
                  autocorrect: false,
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                  decoration: const InputDecoration(
                    labelText: 'Phone number, username or email',
                    prefixIcon: Icon(Icons.person_search_outlined),
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _send(),
                ),
                const SizedBox(height: 12),
                const SizedBox(height: 6),
                NeonActionButton(
                  label: 'Send challenge',
                  busy: _busy,
                  onPressed: _send,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: text.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                // Recent opponents - tap to re-challenge without retyping.
                // BELOW the input on purpose: the list loads asynchronously,
                // and above the field it pushed the box down mid-typing so the
                // first letters landed nowhere (found live, 2026-11-08).
                if (_recent.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Recent', style: text.labelMedium),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: _recent
                        .map(
                          (p) => ActionChip(
                            avatar: const Icon(Icons.replay, size: 16),
                            label: Text(p['username'] as String? ?? 'Player'),
                            onPressed: _busy
                                ? null
                                : () => _sendToUid(
                                    p['uid'] as String,
                                    p['username'] as String? ?? 'them',
                                  ),
                          ),
                        )
                        .toList(),
                  ),
                ],
                if (_sent != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: scheme.primary,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _sent!,
                            style: text.bodyMedium?.copyWith(
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_outgoing.isNotEmpty || _invites.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text('Sent', style: text.titleMedium),
                  const SizedBox(height: 8),
                  ..._outgoing.map(
                    (c) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.hourglass_empty, size: 18),
                      title: Text('Waiting on ${c['toUsername']}'),
                      trailing: ExpiryCountdown(expiresAtMs: c['expiresAtMs']),
                    ),
                  ),
                  ..._invites.map(
                    (c) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.sms_outlined, size: 18),
                      title: Text('Invited ${_prettyPhone(c['phone'])}'),
                      subtitle: const Text('Waiting for them to join'),
                      trailing: TextButton(
                        onPressed: () =>
                            _inviteBySms(c['phone'] as String? ?? '', null),
                        child: const Text('Text again'),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// "+16195551234" -> "(619) 555-1234"; anything else is shown as-is.
String _prettyPhone(Object? raw) {
  final p = raw is String ? raw : '';
  final m = RegExp(r'^\+1(\d{3})(\d{3})(\d{4})$').firstMatch(p);
  return m == null ? p : '(${m[1]}) ${m[2]}-${m[3]}';
}

/// Takes an accepted challenge straight into the camera check + battle.
///
/// NO recording-consent step: friend battles are PRIVATE now (not recorded,
/// judged or clipped - see RECORDED_MODES), so there is nothing to consent to,
/// and dropping it also removes the extra screen people were backing out of.
Future<void> startChallengeMatch(BuildContext context, String matchId) async {
  // Recording consent is BACK for friend battles (2026-11-09): they are
  // recorded again so strangers can judge them, so the same distinct
  // affirmative step every recorded battle has. No live-watch opt-in -
  // friend battles aren't spectatable.
  final consented = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => const RecordingConsentScreen()),
  );
  if (consented != true || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PreMatchScreen(mode: 'friend', challengeMatchId: matchId),
    ),
  );
}
