import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// A battler's MARKETING-USE consent for one of their battles.
///
/// Deliberately SEPARATE from the two consents that already exist: recording
/// consent (given before every match, covers recording + in-app judging) and
/// the takedown / objection window (opt-out before a clip is published to our
/// OWN surfaces). This is the explicit "yes, The Bully League can feature THIS
/// clip in its own promos / official socials (TikTok, IG, YouTube)".
///
/// The official-posting strategy needs it from BOTH battlers before a clip goes
/// out as the company's advertising - being cast in someone's ad is a different
/// ask from playing a judged match. The /admin Post Studio surfaces the ✅/⚠️/❌
/// flag off these answers. Writes via functions/marketingConsent.js
/// (participant-only); clients read the field straight off the match doc.
class MarketingConsentSheet extends StatefulWidget {
  const MarketingConsentSheet({super.key, required this.matchId});

  final String matchId;

  static Future<void> show(BuildContext context, String matchId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => MarketingConsentSheet(matchId: matchId),
    );
  }

  @override
  State<MarketingConsentSheet> createState() => _MarketingConsentSheetState();
}

class _MarketingConsentSheetState extends State<MarketingConsentSheet> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  bool? _consent; // my answer: true = yes, false = no, null = not answered

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('matches')
          .doc(widget.matchId)
          .get();
      final mc = (snap.data()?['marketingConsent'] as Map?) ?? const {};
      final mine = mc[uid] as Map?;
      if (mounted) {
        setState(() {
          _consent = mine == null ? null : mine['consent'] == true;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _set(bool consent) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('setMatchMarketingConsent')
          .call({'matchId': widget.matchId, 'consent': consent});
      if (mounted) {
        setState(() {
          _consent = consent;
          _busy = false;
        });
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message ?? "Couldn't save that.";
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = "Couldn't save that - try again.";
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 4,
          bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Feature this in our promos?',
                      style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    "If you AND your opponent both say yes, this battle could "
                    "show up in The Bully League's own promos - our official "
                    "TikTok, Instagram and YouTube. Nothing goes out unless you "
                    "both agree, and you can change your mind here any time.",
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  if (_consent != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _consent!
                            ? "You're good with it being used."
                            : "You've said no for this one.",
                        style: theme.textTheme.labelLarge?.copyWith(
                            color: _consent! ? scheme.primary : scheme.error),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!, style: TextStyle(color: scheme.error)),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed:
                              _busy || _consent == true ? null : () => _set(true),
                          child: const Text('Yes, use it'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy || _consent == false
                              ? null
                              : () => _set(false),
                          child: const Text('No thanks'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}
