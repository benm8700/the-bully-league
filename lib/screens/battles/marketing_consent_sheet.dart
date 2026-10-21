import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// A battler's MARKETING-USE preference for one of their battles.
///
/// Promo use is okayed UPFRONT (the recording-consent acknowledgement), so a
/// clip is IN by default. Here they can, per clip:
///   - "Blur my face" - the easy opt-out: their opponent's clip still runs, but
///     their own panel is blurred in any posted version (face hidden, audio
///     kept). Most people are fine with this.
///   - "Remove it entirely" - a quiet, secondary (but one-tap, so withdrawal
///     stays easy) full pull: the clip is not posted at all.
///
/// Writes via functions/marketingConsent.js (participant-only), stored at
/// match.marketingConsent.{uid}={mode,at}; the Post Studio renders the blurred
/// cut for "blur" and skips "out".
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
  String _mode = 'in'; // in | blur | out
  bool _posted = false; // already up on our socials

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
      final mode = (mc[uid] as Map?)?['mode'] as String?;
      final posted = (data?['postStudio'] as Map?)?['status'] == 'posted';
      if (mounted) {
        setState(() {
          _mode = (mode == 'blur' || mode == 'out') ? mode! : 'in';
          _posted = posted;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _set(String mode) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('setMatchMarketingConsent')
          .call({'matchId': widget.matchId, 'mode': mode});
      if (mounted) {
        setState(() {
          _mode = mode;
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

  // The FULL pull. Easy (one tap + one confirm), honest upside reminder - not
  // a guilt-trip - because this is where they actually give up the exposure.
  Future<void> _confirmRemoveEntirely() async {
    final body = _posted
        ? "You don't have to win to go viral. Are you sure you want to give up "
            "your chance to get seen?\n\nThis clip is already up on our socials "
            "- remove it and we'll take it down from our accounts."
        : "You don't have to win to go viral. Are you sure you want to give up "
            "your chance to get seen?";
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hold up'),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Make me famous'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Keep me off the stage'),
          ),
        ],
      ),
    );
    if (ok == true) await _set('out');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (String stateLine, Color stateColor) = switch (_mode) {
      'blur' => ('Your face is blurred in this clip.', scheme.primary),
      'out' => ('This clip is kept out of our promos.', scheme.error),
      _ => ('This clip is in our promos.', scheme.primary),
    };
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
                  Text('Use this in our promos',
                      style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    "When you joined, you okayed us featuring your battles in our "
                    "promos. If you'd rather not be seen in THIS one, blur your "
                    "face - your opponent's clip still runs - or pull it "
                    "entirely.",
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(stateLine,
                        style: theme.textTheme.labelLarge
                            ?.copyWith(color: stateColor)),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child:
                          Text(_error!, style: TextStyle(color: scheme.error)),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: switch (_mode) {
                      'out' => FilledButton(
                          onPressed: _busy ? null : () => _set('in'),
                          child: const Text('Allow it in our promos'),
                        ),
                      'blur' => OutlinedButton(
                          onPressed: _busy ? null : () => _set('in'),
                          child: const Text('Show my face again'),
                        ),
                      _ => OutlinedButton(
                          onPressed: _busy ? null : () => _set('blur'),
                          child: const Text('Blur my face'),
                        ),
                    },
                  ),
                  if (_mode != 'out')
                    Align(
                      alignment: Alignment.center,
                      child: TextButton(
                        onPressed: _busy ? null : _confirmRemoveEntirely,
                        style: TextButton.styleFrom(
                            foregroundColor: scheme.onSurfaceVariant),
                        child: const Text('Remove it entirely'),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
