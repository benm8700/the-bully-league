import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/services/main_stage_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/home/rank_badges.dart';

/// The #1 seed's callout: three candidates on ONE screen, tap to pick, confirm,
/// and the bracket is built. The research is front-loaded into the week's
/// qualifier ("Tonight's Field"), so this is a fast dramatic PICK, not a
/// research session - exactly three faces, no scrolling. See the tournament
/// decision record's callout-screen spec.
class MainStageCalloutScreen extends StatefulWidget {
  const MainStageCalloutScreen({
    super.key,
    required this.tournamentId,
    required this.candidates,
    this.service,
  });

  final String tournamentId;
  final List<String> candidates;
  final MainStageService? service;

  @override
  State<MainStageCalloutScreen> createState() => _MainStageCalloutScreenState();
}

class _CandidateInfo {
  _CandidateInfo(this.uid, this.username, this.photoUrl, this.rankTitle);
  final String uid;
  final String? username;
  final String? photoUrl;
  final String? rankTitle;
  String get display => username ?? 'A finalist';
}

class _MainStageCalloutScreenState extends State<MainStageCalloutScreen> {
  late final MainStageService _service = widget.service ?? MainStageService();
  List<_CandidateInfo> _cands = const [];
  String? _selected;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final out = <_CandidateInfo>[];
    for (final uid in widget.candidates) {
      String? name;
      String? photo;
      String? rank;
      try {
        final s = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get();
        final d = s.data();
        name = d?['username'] as String?;
        rank = d?['rankTitle'] as String?;
        final photos = (d?['profile'] as Map?)?['photoUrls'];
        if (photos is List && photos.isNotEmpty) photo = photos.first as String?;
      } catch (_) {/* a candidate we can't resolve still shows as a finalist */}
      out.add(_CandidateInfo(uid, name, photo, rank));
    }
    if (!mounted) return;
    setState(() {
      _cands = out;
      _loading = false;
    });
  }

  Future<void> _confirm() async {
    final pick = _cands.firstWhere((c) => c.uid == _selected);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Call out ${pick.display}?'),
        content: const Text(
          "They're your semifinal opponent. This locks the bracket and goes "
          'live on stage — no takebacks.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Call out ${pick.display}'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _service.callout(widget.tournamentId, pick.uid);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = "Couldn't lock that in — try again.");
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gold = context.palette.reward;
    final text = Theme.of(context).textTheme;
    final bottom = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      appBar: AppBar(title: const Text('Your callout')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottom),
              children: [
                Text("You're the #1 seed", style: text.titleLarge),
                const SizedBox(height: 6),
                Text(
                  'Pick who you want in your semifinal. Call out your rival, not '
                  'the easy mark — the crowd is watching.',
                  style: text.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                for (final c in _cands) _candidateCard(c, gold),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: TextStyle(color: context.palette.live)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: gold,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(0, 52),
                  ),
                  onPressed:
                      (_selected == null || _submitting) ? null : _confirm,
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_selected == null
                          ? 'Pick an opponent'
                          : 'Call out ${_cands.firstWhere((c) => c.uid == _selected).display}'),
                ),
              ],
            ),
    );
  }

  Widget _candidateCard(_CandidateInfo c, Color gold) {
    final selected = c.uid == _selected;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: selected ? gold.withValues(alpha: 0.14) : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _submitting ? null : () => setState(() => _selected = c.uid),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? gold : Colors.transparent,
                width: 2,
              ),
            ),
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                _avatar(c),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.display,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      if (c.rankTitle != null)
                        Text(c.rankTitle!,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle, color: gold)
                else
                  Icon(Icons.radio_button_unchecked,
                      color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _avatar(_CandidateInfo c) {
    const size = 52.0;
    if (c.photoUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(c.photoUrl!,
            width: size, height: size, fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _crest(c, size)),
      );
    }
    return _crest(c, size);
  }

  Widget _crest(_CandidateInfo c, double size) {
    final asset = c.rankTitle == null ? null : rankBadgeAsset(c.rankTitle!);
    if (asset != null) {
      return RankBadge(title: c.rankTitle!, size: size);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.person),
    );
  }
}
