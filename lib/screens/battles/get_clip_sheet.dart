import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Getting the shareable version of one of your own battles.
///
/// WHAT IS ACTUALLY BEING BOUGHT, because it is easy to get wrong: every
/// ranked match already gets a clip - in-app judging needs one, and that
/// render costs almost nothing. The expensive part is transcription, so
/// what this buys is the CAPTIONED cut, which is also the version that
/// works on TikTok and Reels where nearly everyone watches muted. The copy
/// below says "captions" rather than "your clip" for that reason: claiming
/// to sell something the app already gives away would read as a con the
/// first time someone noticed their battle in the feed.
///
/// Three ways to get it, resolved server-side in functions/clipGrants.js -
/// included with a subscription, bought with points, or purchased outright
/// once IAP exists.
class GetClipSheet extends StatefulWidget {
  const GetClipSheet({super.key, required this.matchId});

  final String matchId;

  static Future<void> show(BuildContext context, String matchId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => GetClipSheet(matchId: matchId),
    );
  }

  @override
  State<GetClipSheet> createState() => _GetClipSheetState();
}

class _GetClipSheetState extends State<GetClipSheet> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _done;

  int _balance = 0;
  int _price = 250;
  bool _subscriber = false;
  bool _alreadyOwned = false;
  int? _availableAfterMs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final db = FirebaseFirestore.instance;
      final results = await Future.wait([
        db.collection('users').doc(uid).get(),
        db.collection('config').doc('pointsSettings').get(),
        db.collection('matches').doc(widget.matchId).get(),
      ]);
      final user = results[0].data() ?? {};
      final settings = results[1].data() ?? {};
      final match = results[2].data() ?? {};

      // A missing balance means this account predates spending and has by
      // definition spent nothing, so its balance is its career total -
      // mirrors spendableBalance in functions/clipGrants.js. Showing 0 here
      // would tell someone they were broke when they were not.
      final rawBalance = user['pointsBalance'] ?? user['points'];
      final grants = match['clipGrants'] as Map<String, dynamic>?;

      if (!mounted) return;
      setState(() {
        _balance = (rawBalance as num?)?.toInt() ?? 0;
        _price = (settings['clipPrice'] as num?)?.toInt() ?? 250;
        _subscriber = (user['subscription']
            as Map<String, dynamic>?)?['active'] == true;
        _alreadyOwned = grants?[uid] != null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Couldn't load your clip options.";
        });
      }
    }
  }

  Future<void> _request(String source) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('requestMatchClip')
          .call<Map<String, dynamic>>({
        'matchId': widget.matchId,
        'source': source,
      });
      final data = result.data;
      if (!mounted) return;
      setState(() {
        _busy = false;
        _alreadyOwned = true;
        _availableAfterMs = (data['availableAfterMs'] as num?)?.toInt();
        _done = data['deliverable'] == true
            ? 'Captions are being added. Your clip will be ready shortly.'
            : 'Booked. Your clip arrives once voting closes.';
        if (source == 'points') _balance -= _price;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? 'Something went wrong.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Something went wrong.';
      });
    }
  }

  /// Fetches a short-lived signed URL and opens it.
  ///
  /// The server refuses if the clip is still rendering, still inside the
  /// opponent's objection window, or was taken down - and its message says
  /// which, so a refusal is informative rather than a dead end.
  Future<void> _download() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getClipDownload')
          .call<Map<String, dynamic>>({'matchId': widget.matchId});
      final urls = (result.data['urls'] as Map?)?.cast<String, dynamic>();
      // Vertical first: this is the cut people actually post, and the
      // landscape one is a letterboxed strip on a phone.
      final url = urls?['vertical'] ?? urls?['landscape'];
      if (url == null) throw Exception('no url');
      final opened = await launchUrl(Uri.parse(url as String),
          mode: LaunchMode.externalApplication);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = opened ? 'Downloading your clip.' : null;
        if (!opened) _error = "Couldn't open the download.";
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? 'Your clip is not ready yet.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "Couldn't start the download.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: _loading
          ? const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Get your clip', style: text.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  'The captioned cut, ready to post. Captions matter more '
                  'than they sound - most people watch with the sound off.',
                  style: text.bodyMedium,
                ),
                const SizedBox(height: 20),
                if (_done != null) ...[
                  _Notice(icon: Icons.check_circle_outline, text: _done!),
                  if (_availableAfterMs != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      // Said plainly rather than buried: someone who paid
                      // and saw nothing arrive would reasonably assume it
                      // had failed.
                      'Held until your opponent\'s chance to object has '
                      'passed. That is the same protection you get.',
                      style: text.bodySmall,
                    ),
                  ],
                ] else if (_alreadyOwned) ...[
                  const _Notice(
                    icon: Icons.check_circle_outline,
                    text: 'This clip is already yours.',
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    _Notice(icon: Icons.error_outline, text: _error!),
                    const SizedBox(height: 12),
                  ],
                  FilledButton.icon(
                    onPressed: _busy ? null : _download,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Download'),
                  ),
                ] else ...[
                  if (_error != null) ...[
                    _Notice(icon: Icons.error_outline, text: _error!),
                    const SizedBox(height: 12),
                  ],
                  if (_subscriber)
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _request('subscription'),
                      icon: const Icon(Icons.workspace_premium_outlined),
                      label: const Text('Included with your subscription'),
                    )
                  else ...[
                    FilledButton(
                      onPressed: _busy || _balance < _price
                          ? null
                          : () => _request('points'),
                      child: Text('Use $_price points'),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _balance >= _price
                          ? 'You have $_balance points'
                          : 'You have $_balance of $_price points',
                      style: text.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Subscribers get every ranked battle captioned '
                      'automatically.',
                      style: text.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
      ],
    );
  }
}
