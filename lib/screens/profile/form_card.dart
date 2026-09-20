import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Naming whoever invited you.
///
/// Shown only to players who have NOT yet played, because that is the
/// only window in which it can be set - allowing it later would let
/// someone attach a referrer retroactively once they knew it paid. It
/// disappears entirely once used or once they battle, rather than
/// lingering as a dead control.
///
/// The reward lands on THEIR side, not yours, and only once you have
/// actually played - so this is worth surfacing honestly rather than
/// dressing up as a bonus for the person filling it in.
class ReferrerField extends StatefulWidget {
  const ReferrerField({super.key});

  @override
  State<ReferrerField> createState() => _ReferrerFieldState();
}

class _ReferrerFieldState extends State<ReferrerField> {
  final _controller = TextEditingController();
  bool _visible = false;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final d = snap.data() ?? {};
      final played = ((d['rankedMatchesPlayed'] as num?) ?? 0) +
          ((d['exhibitionMatchesPlayed'] as num?) ?? 0);
      if (mounted) {
        setState(() =>
            _visible = d['referredByUserId'] == null && played == 0);
      }
    } catch (_) {
      // Not worth an error state - the field simply stays hidden.
    }
  }

  Future<void> _submit() async {
    final name = _controller.text.trim();
    if (name.length < 2) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('setReferrer')
          .call<Map<String, dynamic>>({'username': name});
      if (!mounted) return;
      setState(() {
        _busy = false;
        _visible = false;
        _message = '${result.data['referrer']} will get credit once you '
            'play your first battle.';
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = e.message ?? "Couldn't save that.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) {
      if (_message == null) return const SizedBox.shrink();
      return _Section(
        title: 'Invited by',
        child: Text(_message!,
            style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return _Section(
      title: 'Invited by',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Someone bring you here? Put their username in and they get '
            'credit once you play your first battle.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(labelText: 'Their username'),
          ),
          if (_message != null) ...[
            const SizedBox(height: 8),
            Text(_message!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _submit,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/// Your own invite, ready to send.
///
/// WITHOUT THIS THE REFERRAL SYSTEM IS BARELY USABLE. Attribution is by
/// username, so inviting someone means them being TOLD a username,
/// remembering it through an install and a signup, and typing it
/// correctly. A one-tap copy removes most of that.
///
/// Deliberately NOT a deep link. A real one needs link infrastructure
/// (Firebase Dynamic Links is gone) plus install-time attribution, which
/// is a genuine project rather than a detail - and a copyable line works
/// today, in any app someone already talks to their friends in.
class InviteCard extends StatefulWidget {
  const InviteCard({super.key});

  @override
  State<InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends State<InviteCard> {
  String? _username;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (mounted) {
        setState(() => _username = snap.data()?['username'] as String?);
      }
    } catch (_) {
      // No card rather than an error - this is an extra, not a feature
      // the profile depends on.
    }
  }

  String get _message =>
      'Come get roasted on The Bully League. Put "$_username" in as who '
      'invited you.';

  @override
  Widget build(BuildContext context) {
    final name = _username;
    if (name == null || name.isEmpty) return const SizedBox.shrink();
    return _Section(
      title: 'Invite someone',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            // States the condition honestly rather than implying the
            // reward lands on signup - it does not, deliberately.
            'You earn points when someone you invited actually judges a '
            'battle, and more when they play one.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _message));
              if (!mounted) return;
              setState(() => _copied = true);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invite copied. Go paste it.')),
                );
              }
            },
            icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
            label: Text(_copied ? 'Copied' : 'Copy your invite'),
          ),
        ],
      ),
    );
  }
}

/// Your public name, and the only way to change it.
///
/// This is also the RECOVERY PATH for a signup whose name claim failed -
/// someone else taking the name in the same second leaves an account with
/// no username at all, and every other screen quietly falls back to
/// "Roaster". Without this control that account could never be fixed.
///
/// The cooldown is stated up front rather than discovered on submit,
/// because a change you cannot undo for a month is a decision, not a
/// tweak.
class UsernameCard extends StatefulWidget {
  const UsernameCard({super.key});

  @override
  State<UsernameCard> createState() => _UsernameCardState();
}

class _UsernameCardState extends State<UsernameCard> {
  Map<String, dynamic>? _state;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Runs from initState. Because the Profile tab lives in MainShell's
    // IndexedStack, this widget is built EAGERLY at login/signup (not when the
    // tab is first opened) and NEVER re-inits. That exposed a real device bug
    // (2026-09-01): right after signup this callable can win a race against
    // setUsername and come back with username:null, and the null result was
    // then cached for the whole session - showing a false "You have not picked
    // one yet / Pick a username" to someone who just chose a name. A cold-start
    // transient (Firebase Installations warming up) is the other way it fails.
    // So retry until a real name arrives (or a bounded give-up for the genuine
    // legacy username-less account), and only commit a null-name state at the
    // end so the false control never flashes.
    Map<String, dynamic>? last;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final result = await FirebaseFunctions.instance
            .httpsCallable('getUsernameState')
            .call<Map<String, dynamic>>();
        last = result.data;
        final name = last['username'] as String?;
        if (name != null && name.isNotEmpty) {
          if (mounted) setState(() => _state = last);
          return;
        }
      } catch (_) {
        // Fall through to the backoff + retry.
      }
      if (!mounted) return;
      if (attempt < 4) {
        await Future.delayed(Duration(milliseconds: 500 * (1 << attempt)));
      }
    }
    // Retries exhausted: commit whatever we last saw. A genuinely name-less
    // (legacy) account legitimately gets the "Pick a username" control here.
    if (mounted && last != null) setState(() => _state = last);
  }

  Future<void> _change() async {
    final controller = TextEditingController(
      text: _state?['username'] as String? ?? '',
    );
    final cooldownDays = (_state?['cooldownDays'] as num?)?.toInt() ?? 30;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change username'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 20,
              decoration: const InputDecoration(labelText: 'New username'),
            ),
            Text(
              'After this you have to wait $cooldownDays days before '
              'changing it again.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Change it'),
          ),
        ],
      ),
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;

    setState(() => _busy = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('setUsername')
          .call<Map<String, dynamic>>({'username': chosen});
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('You are $chosen now.')),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      // The server's own message is shown verbatim - it is the one that
      // knows whether this was taken, refused or too soon.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Could not change that.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (state == null) return const SizedBox.shrink();
    final name = state['username'] as String?;
    final canChange = state['canChange'] == true;
    final locked = state['message'] as String?;

    return _Section(
      title: 'Username',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            name?.isNotEmpty == true ? name! : 'You have not picked one yet.',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            locked ??
                'Public - it appears on the leaderboard, in the feed and on '
                    'any clip of yours that gets posted.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            // Never picked one is always changeable, whatever the
            // cooldown says - otherwise a failed signup claim would lock
            // someone out of having a name at all.
            onPressed: _busy || !(canChange || name == null) ? null : _change,
            child: Text(name == null ? 'Pick a username' : 'Change username'),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        child,
        const SizedBox(height: 24),
      ],
    );
  }
}
