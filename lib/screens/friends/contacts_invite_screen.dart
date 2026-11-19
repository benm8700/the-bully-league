import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../../core/contact_hash.dart';

/// What the player picked: challenge a member, or invite a number.
class ContactPick {
  const ContactPick.member(this.uid, this.name) : phone = null;
  const ContactPick.invite(this.phone, this.name) : uid = null;
  final String? uid;
  final String? phone;
  final String name;
}

/// "Find friends from contacts" (2026-11-19, developer: make inviting
/// seamless). Privacy, by design:
///  - an explainer BEFORE the system prompt; saying no costs nothing (typing a
///    number still works);
///  - only hashed numbers leave the phone (lib/core/contact_hash.dart); the
///    server answers which belong to findable members and stores nothing;
///  - one invite per tap, sent by the player from their own Messages app - no
///    bulk texting, no server-sent SMS.
/// Pops a [ContactPick]; ChallengeScreen does the sending.
class ContactsInviteScreen extends StatefulWidget {
  const ContactsInviteScreen({super.key});

  @override
  State<ContactsInviteScreen> createState() => _ContactsInviteScreenState();
}

enum _Stage { explain, loading, denied, ready, error }

class _Row {
  _Row(this.name, this.e164);
  final String name;
  final String e164;
  String? uid;
  String? username;
  String? photoUrl;
}

class _ContactsInviteScreenState extends State<ContactsInviteScreen> {
  _Stage _stage = _Stage.explain;
  List<_Row> _members = const [];
  List<_Row> _others = const [];
  String _query = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _skipExplainIfGranted();
  }

  /// Already allowed earlier: go straight to the list.
  Future<void> _skipExplainIfGranted() async {
    try {
      final s = await FlutterContacts.permissions.check(PermissionType.read);
      if (s == PermissionStatus.granted || s == PermissionStatus.limited) {
        _load();
      }
    } catch (_) {}
  }

  Future<void> _allow() async {
    setState(() => _stage = _Stage.loading);
    try {
      final s = await FlutterContacts.permissions.request(PermissionType.read);
      if (s != PermissionStatus.granted && s != PermissionStatus.limited) {
        if (mounted) setState(() => _stage = _Stage.denied);
        return;
      }
      await _load();
    } catch (_) {
      if (mounted) setState(() => _stage = _Stage.denied);
    }
  }

  Future<void> _load() async {
    if (mounted) setState(() => _stage = _Stage.loading);
    try {
      final contacts = await FlutterContacts.getAll(
        properties: {ContactProperty.name, ContactProperty.phone},
      );
      // One row per distinct number; first name seen wins.
      final byNumber = <String, _Row>{};
      for (final c in contacts) {
        final name = (c.displayName ?? '').trim();
        for (final p in c.phones) {
          final e164 = normalizeE164(p.normalizedNumber ?? p.number) ??
              normalizeE164(p.number);
          if (e164 == null) continue;
          byNumber.putIfAbsent(
            e164,
            () => _Row(name.isEmpty ? p.number : name, e164),
          );
        }
      }
      final rows = byNumber.values.toList();
      final byHash = {for (final r in rows) phoneHash(r.e164): r};
      final hashes = byHash.keys.toList();
      final fn = FirebaseFunctions.instance.httpsCallable('matchContacts');
      for (var i = 0; i < hashes.length; i += 500) {
        final chunk = hashes.sublist(
          i,
          i + 500 > hashes.length ? hashes.length : i + 500,
        );
        final r = await fn.call<Map<String, dynamic>>({'hashes': chunk});
        for (final m in (r.data['matches'] as List? ?? const [])) {
          final mm = (m as Map).cast<String, dynamic>();
          final row = byHash[mm['hash']];
          if (row == null) continue;
          row.uid = mm['uid'] as String?;
          row.username = mm['username'] as String?;
          row.photoUrl = mm['photoUrl'] as String?;
        }
      }
      int byName(_Row a, _Row b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (!mounted) return;
      setState(() {
        _members = rows.where((r) => r.uid != null).toList()..sort(byName);
        _others = rows.where((r) => r.uid == null).toList()..sort(byName);
        _stage = _Stage.ready;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _stage = _Stage.error;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = "Couldn't read your contacts.";
        _stage = _Stage.error;
      });
    }
  }

  bool _hit(_Row r) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    final qDigits = q.replaceAll(RegExp(r'\D'), '');
    return r.name.toLowerCase().contains(q) ||
        (r.username ?? '').toLowerCase().contains(q) ||
        (qDigits.length >= 3 && r.e164.contains(qDigits));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Friends from contacts')),
      body: switch (_stage) {
        _Stage.explain => _explain(context),
        _Stage.loading => const Center(child: CircularProgressIndicator()),
        _Stage.denied => _message(
          context,
          'No problem',
          "Contacts are off, so you can still type a friend's number on the "
              'last screen. You can turn contacts on any time in Settings.',
          action: TextButton(
            onPressed: () => FlutterContacts.permissions.openSettings(),
            child: const Text('Open Settings'),
          ),
        ),
        _Stage.error => _message(
          context,
          'Something went wrong',
          _error ?? 'Try again in a moment.',
          action: TextButton(onPressed: _load, child: const Text('Try again')),
        ),
        _Stage.ready => _list(context),
      },
    );
  }

  Widget _explain(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget point(IconData icon, String s) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: const Color(0xFFFF2E7E)),
          const SizedBox(width: 12),
          Expanded(child: Text(s, style: text.bodyMedium)),
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Find your friends', style: text.headlineSmall),
        const SizedBox(height: 8),
        Text(
          "See who's already here and invite the rest with one tap.",
          style: text.bodyMedium,
        ),
        const SizedBox(height: 24),
        point(
          Icons.lock_outline,
          'Numbers are scrambled on your phone before anything is sent. We '
              'never see or keep your contact list.',
        ),
        point(
          Icons.person_off_outlined,
          'Names and emails never leave your phone.',
        ),
        point(
          Icons.sms_outlined,
          'Nobody gets a text unless you tap Invite and hit Send yourself.',
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _allow, child: const Text('Continue')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Not now'),
        ),
      ],
    );
  }

  Widget _message(
    BuildContext context,
    String title,
    String body, {
    Widget? action,
  }) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: text.titleLarge),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 12), action],
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final members = _members.where(_hit).toList();
    final others = _others.where(_hit).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            onChanged: (v) => setState(() => _query = v.trim()),
            onTapOutside: (_) => FocusScope.of(context).unfocus(),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search contacts',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              if (members.isNotEmpty) ...[
                _header(text, 'On The Bully League'),
                ...members.map(
                  (r) => ListTile(
                    leading: CircleAvatar(
                      backgroundImage: r.photoUrl != null
                          ? NetworkImage(r.photoUrl!)
                          : null,
                      child: r.photoUrl == null
                          ? Text(r.name.characters.first.toUpperCase())
                          : null,
                    ),
                    title: Text(r.name),
                    subtitle: Text('@${r.username ?? 'player'}'),
                    trailing: FilledButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).pop(ContactPick.member(r.uid!, r.username ?? r.name)),
                      child: const Text('Challenge'),
                    ),
                  ),
                ),
              ],
              _header(text, 'Invite to The Bully League'),
              if (others.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No other contacts with a phone number.'),
                ),
              ...others.map(
                (r) => ListTile(
                  leading: CircleAvatar(
                    child: Text(
                      r.name.isEmpty
                          ? '?'
                          : r.name.characters.first.toUpperCase(),
                    ),
                  ),
                  title: Text(r.name),
                  subtitle: Text(r.e164),
                  trailing: OutlinedButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(ContactPick.invite(r.e164, r.name)),
                    child: const Text('Invite'),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(TextTheme text, String s) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
    child: Text(s.toUpperCase(), style: text.labelMedium),
  );
}
