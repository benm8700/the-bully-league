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
  bool _posted = false; // this clip is already up on our socials

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
      final data = snap.data();
      final mc = (data?['marketingConsent'] as Map?) ?? const {};
      final mine = mc[uid] as Map?;
      final posted = (data?['postStudio'] as Map?)?['status'] == 'posted';
      if (mounted) {
        setState(() {
          _consent = mine == null ? null : mine['consent'] == true;
          _posted = posted;
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

  // An opt-out is one tap + one confirm - deliberately easy (withdrawing
  // promo use must be as simple as it was given). The confirm is an honest
  // reminder of the upside, NOT a guilt-trip: both great and terrible sets can
  // blow up, which is the whole point of being here.
  Future<void> _confirmAndOptOut() async {
    final body = _posted
        ? "Both good AND bad performances can blow up and get you noticed - "
            "that's the whole point of being here. This clip is already up on "
            "our socials; opt out and we'll take it down from our accounts."
        : "Both good AND bad performances can blow up and get you noticed - "
            "that's the whole point of being here. Opt out and we'll keep this "
            "clip out of our promos.";
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sure you want to opt out?'),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it in'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Opt out'),
          ),
        ],
      ),
    );
    if (ok == true) await _set(false);
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
            : Builder(builder: (context) {
                // Default IN: when you joined, you okayed us featuring your
                // battles in our promos, so a clip is in by default. Only an
                // explicit opt-out (consent == false) keeps THIS one out.
                final optedOut = _consent == false;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Use this in our promos',
                        style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      "When you joined, you okayed us featuring your battles in "
                      "The Bully League's promos - so this one's in by default. "
                      "If you'd rather we didn't use THIS clip, keep it out "
                      "below. You can flip it back any time.",
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        optedOut
                            ? "This clip is kept OUT of our promos."
                            : "This clip is in our promos.",
                        style: theme.textTheme.labelLarge?.copyWith(
                            color: optedOut ? scheme.error : scheme.primary),
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child:
                            Text(_error!, style: TextStyle(color: scheme.error)),
                      ),
                    SizedBox(
                      width: double.infinity,
                      child: optedOut
                          ? FilledButton(
                              onPressed: _busy ? null : () => _set(true),
                              child: const Text('Allow it in our promos'),
                            )
                          : OutlinedButton(
                              onPressed: _busy ? null : _confirmAndOptOut,
                              child: const Text('Keep this one out'),
                            ),
                    ),
                  ],
                );
              }),
      ),
    );
  }
}
