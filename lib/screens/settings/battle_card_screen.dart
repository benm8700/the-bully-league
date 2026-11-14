import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/battle_card.dart';
import '../../widgets/country_picker.dart';
import '../../widgets/neon_action_button.dart';

/// Settings > Battle card (2026-11-14). The name, location and "about me" set
/// in the ranked setup flow, kept off the Profile page. Name, city and
/// country can be CHANGED only once every 30 days, but can always be cleared
/// (privacy/safety) or filled in if blank. "About me" changes any time.
class BattleCardScreen extends StatefulWidget {
  const BattleCardScreen({super.key});

  @override
  State<BattleCardScreen> createState() => _BattleCardScreenState();
}

class _BattleCardScreenState extends State<BattleCardScreen> {
  final _name = TextEditingController();
  final _city = TextEditingController();
  final _about = TextEditingController();
  String? _country;

  // What's saved now, to tell a change from a fill or a clear.
  String _savedName = '';
  String _savedCity = '';
  String _savedCountry = '';
  DateTime? _lockedUntil;

  bool _loading = true;
  bool _saving = false;
  String? _message;

  DocumentReference<Map<String, dynamic>> get _userRef => FirebaseFirestore
      .instance
      .collection('users')
      .doc(FirebaseAuth.instance.currentUser!.uid);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final snap = await _userRef.get();
    final data = snap.data();
    final p = (data?['profile'] as Map?) ?? const {};
    String s(Object? v) => (v is String) ? v.trim() : '';
    if (!mounted) return;
    setState(() {
      _savedName = s(p['name']);
      _savedCity = s(p['hometown']);
      _savedCountry = s(p['country']);
      _name.text = _savedName;
      _city.text = _savedCity;
      _country = _savedCountry.isEmpty ? null : _savedCountry;
      _about.text = s(p['ammoText']);
      _lockedUntil = battleCardLockedUntil(data);
      _loading = false;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _city.dispose();
    _about.dispose();
    super.dispose();
  }

  String _fmtDate(DateTime d) {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${m[d.month - 1]} ${d.day}';
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final name = _name.text.trim();
    final city = _city.text.trim();
    final country = _country ?? '';
    final changed =
        isLockedChange(_savedName, name) ||
        isLockedChange(_savedCity, city) ||
        isLockedChange(_savedCountry, country);
    if (changed && _lockedUntil != null) {
      setState(
        () => _message =
            'Name, city and country can change again on '
            '${_fmtDate(_lockedUntil!)}. You can clear them any time.',
      );
      return;
    }
    final fields = {
      'name': name,
      'hometown': city,
      'country': country,
      'ammoText': _about.text.trim(),
    };
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final blocked = await blockedProfileFields(fields);
      if (blocked.isNotEmpty) {
        setState(() => _message = kProfileTextRefused);
        return;
      }
      await saveProfileFields(_userRef, {
        ...fields,
        if (changed) 'battleCardChangedAt': FieldValue.serverTimestamp(),
      });
      await _load();
      if (mounted) setState(() => _message = 'Saved.');
    } catch (_) {
      if (mounted) {
        setState(() => _message = "Couldn't save. Check your connection.");
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    void unfocus(PointerDownEvent _) =>
        FocusManager.instance.primaryFocus?.unfocus();
    return Scaffold(
      appBar: AppBar(title: const Text('Battle card')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                Text(
                  'What your opponent sees about you during a battle. Only '
                  'your opponent sees where you are from.',
                  style: text.bodyMedium?.copyWith(height: 1.4),
                ),
                if (_lockedUntil != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Name, city and country can change again on '
                    '${_fmtDate(_lockedUntil!)}. You can clear them any time.',
                    style: text.bodySmall,
                  ),
                ],
                const SizedBox(height: 24),
                Text('Name', style: text.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 30,
                  onTapOutside: unfocus,
                  decoration: const InputDecoration(hintText: 'e.g. Mike'),
                ),
                const SizedBox(height: 12),
                Text('City & State', style: text.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _city,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 50,
                  onTapOutside: unfocus,
                  decoration: const InputDecoration(
                    hintText: 'e.g. San Diego, CA',
                  ),
                ),
                const SizedBox(height: 12),
                Text('Country', style: text.titleMedium),
                const SizedBox(height: 8),
                CountryField(
                  code: _country,
                  onPicked: (c) => setState(() => _country = c),
                ),
                if (_country != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setState(() => _country = null),
                      child: const Text('Clear country'),
                    ),
                  ),
                const SizedBox(height: 12),
                Text('About me', style: text.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _about,
                  maxLines: 4,
                  maxLength: 280,
                  onTapOutside: unfocus,
                  decoration: const InputDecoration(
                    hintText:
                        'Who you are, what you do, something embarrassing - '
                        'whatever you want to share.',
                  ),
                ),
                const SizedBox(height: 16),
                if (_message != null) ...[
                  Text(_message!, style: text.bodyMedium),
                  const SizedBox(height: 12),
                ],
                NeonActionButton(
                  label: 'Save',
                  busy: _saving,
                  onPressed: _saving ? null : _save,
                ),
              ],
            ),
    );
  }
}
