import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../widgets/match_clip_player.dart';

/// Getting the shareable version of one of your own battles.
///
/// WHAT IS ACTUALLY BEING BOUGHT, because it is easy to get wrong: every
/// ranked match already gets a clip - in-app judging needs one, and that
/// render costs almost nothing. The expensive part is transcription, so
/// what this buys is the polished, CAPTIONED edit, which is also the version
/// that works on TikTok and Reels. The copy below sells that finished edit -
/// keeping your performance - rather than "your clip" outright: claiming to
/// sell something the app already gives away would read as a con the first
/// time someone noticed their battle in the feed.
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
  bool _freeClipAvailable = false;
  bool _subscriber = false;
  bool _alreadyOwned = false;
  String? _savedNotice;

  // Whether the captioned cut exists yet - the moment Watch/Share/Save can
  // actually work. Watched LIVE while the sheet is open, so a claimed clip
  // goes from "Making your clip" to "ready" in front of the user instead of
  // the old dead-end "check back and tap Watch" with no Watch button in
  // sight (developer's report, 2026-11-08).
  bool _captioned = false;
  bool _justFinished = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _matchSub;

  @override
  void initState() {
    super.initState();
    _load();
    _matchSub = FirebaseFirestore.instance
        .collection('matches')
        .doc(widget.matchId)
        .snapshots()
        .listen((snap) {
          final captioned = clipReady(snap.data());
          if (!mounted || captioned == _captioned) return;
          setState(() {
            // Celebrate only a transition seen while they waited, not a clip
            // that was already done when the sheet opened.
            _justFinished = captioned && _alreadyOwned && !_loading;
            _captioned = captioned;
          });
        }, onError: (_) {});
  }

  @override
  void dispose() {
    _matchSub?.cancel();
    super.dispose();
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
        _subscriber =
            (user['subscription'] as Map<String, dynamic>?)?['active'] == true;
        // Mirrors hasUsedFreeClip in functions/clipGrants.js: only an
        // explicit true counts, so an account predating the free clip
        // still has one rather than being told it is spent.
        _freeClipAvailable = user['freeClipUsed'] != true;
        _alreadyOwned = grants?[uid] != null;
        _captioned = clipReady(match);
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
        if (data['deliverable'] == true) _captioned = true;
        // The server decides what it actually cost - it grants the free
        // clip regardless of what the client asked for, so deducting the
        // price here would show a balance that never left the account.
        final cost = (data['cost'] as num?)?.toInt() ?? 0;
        _balance -= cost;
        if (data['source'] == 'free') _freeClipAvailable = false;
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

  /// Saves the clip straight into the phone's photo library.
  ///
  /// Used to open the download URL in the browser, which on an iPhone lands
  /// the file in the Files app - not where anyone posts from (developer's
  /// report, 2026-11-08). The camera roll is where TikTok / Instagram pick
  /// videos from, so that is where it goes.
  Future<void> _download() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final message = await ClipActions.saveToPhotos(widget.matchId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (message.saved) {
        _savedNotice = message.text;
      } else {
        _error = message.text;
      }
    });
  }

  /// Plays the finished captioned clip IN-APP, so you can watch the edit
  /// before you download or post it - the same file the download/share
  /// buttons hand over, but streamed rather than saved. Uses the streamable
  /// `previewUrl` (no attachment disposition). Gated by the same
  /// objection-window check, since it calls the same endpoint.
  Future<void> _watch() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getClipDownload')
          .call<Map<String, dynamic>>({'matchId': widget.matchId});
      final url = result.data['previewUrl'] as String?;
      if (url == null) throw Exception('no url');
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _ClipPreviewScreen(url: url, matchId: widget.matchId),
          fullscreenDialog: true,
        ),
      );
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
        _error = "Couldn't load your clip.";
      });
    }
  }

  /// Opens the phone's share sheet with the video file attached (TikTok,
  /// Instagram, Snapchat, Messages...). See [ClipActions.share].
  Future<void> _share() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final failure = await ClipActions.share(widget.matchId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
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
                  'Keep your performance. We cut your battle into a clean, '
                  'captioned edit - polished and ready to save and share.',
                  style: text.bodyMedium,
                ),
                const SizedBox(height: 20),
                if (_done != null) ...[
                  _Notice(icon: Icons.check_circle_outline, text: _done!),
                ] else if (_alreadyOwned && !_captioned) ...[
                  // Claimed, captions still being made: say what is
                  // happening, how long, and exactly where to find it.
                  const _MakingClipCard(),
                ] else if (_alreadyOwned) ...[
                  _Notice(
                    icon: _justFinished
                        ? Icons.celebration_outlined
                        : Icons.check_circle_outline,
                    text: _justFinished
                        ? 'Your clip is ready!'
                        : 'This clip is yours.',
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    _Notice(icon: Icons.error_outline, text: _error!),
                    const SizedBox(height: 12),
                  ],
                  if (_savedNotice != null) ...[
                    _Notice(
                      icon: Icons.check_circle_outline,
                      text: _savedNotice!,
                    ),
                    const SizedBox(height: 12),
                  ],
                  // Watch-first: this is the finished captioned edit, so let
                  // people see it in-app before downloading or posting.
                  FilledButton.icon(
                    onPressed: _busy ? null : _watch,
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Watch your clip'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _share,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share to social'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _download,
                    icon: const Icon(Icons.download_outlined),
                    label: Text(ClipActions.saveLabel),
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 12),
                    const Center(
                      child: SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ],
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
                  else if (_freeClipAvailable) ...[
                    // The first one is free, and saying so plainly matters:
                    // someone with 30 points who sees "Use 250 points"
                    // closes the sheet and never learns they could have had
                    // this one. The whole point is that everybody posts a
                    // clip once.
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _request('points'),
                      icon: const Icon(Icons.card_giftcard_outlined),
                      label: const Text('Get it free'),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Your first one is on us. After this they cost '
                      '$_price points.',
                      style: text.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ] else ...[
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
                    if (_balance < _price) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Judge battles and play to earn points.',
                        style: text.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
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

/// The waiting state after a clip is claimed. Captioning runs on the
/// server's render sweep (every 5 minutes), so the honest promise is "under
/// 10 minutes", not "a minute or two". The sheet flips to Watch/Share/Save by
/// itself when it lands; if they leave, a push brings them straight back.
class _MakingClipCard extends StatelessWidget {
  const _MakingClipCard();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text('Making your clip...', style: text.titleMedium),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Adding captions - usually under 10 minutes. Keep this open and '
            "your Watch, Share and Save buttons appear right here.",
            style: text.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            "Or close it: we'll send you a notification when it's ready, and "
            "it lives on this battle in My Battles - tap Watch clip there.",
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}

/// Whether a battle's postable clip is finished: the caption pass has run.
/// Mirrors captionPassDone in functions/clipGrants.js - a battle with no
/// clear speech gets no captions (`captioned` stays false) but its finished
/// cut still exists, and must count as ready or it would wait forever.
bool clipReady(Map<String, dynamic>? match) {
  final h = match?['highlight'] as Map<String, dynamic>?;
  return h?['captioned'] == true || h?['captionedRenderedAt'] != null;
}

/// The outcome of a save: whether it worked and what to tell the player.
class ClipSaveResult {
  const ClipSaveResult(this.saved, this.text);
  final bool saved;
  final String text;
}

/// Save / share for a battle clip, shared by the clip sheet and the watch
/// screen so both behave identically.
class ClipActions {
  ClipActions._();

  /// "Photos" is what iPhone owners call it; Android calls it the gallery.
  static String get saveLabel => defaultTargetPlatform == TargetPlatform.iOS
      ? 'Save to Photos'
      : 'Save to gallery';

  static const _album = 'The Bully League';

  static const shareText =
      'Think you can roast me better? Come get cooked on The Bully '
      'League 🎤🔥 the-bully-league.vercel.app\n'
      '#TheBullyLeague #roastbattle #comedy';

  /// The postable file's signed URL. Vertical first: it's the cut people
  /// post; landscape is a letterboxed strip on a phone. Throws the server's
  /// FirebaseFunctionsException (still rendering, objection, taken down)
  /// so its message reaches the player.
  static Future<String> _fileUrl(String matchId) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('getClipDownload')
        .call<Map<String, dynamic>>({'matchId': matchId});
    final urls = (result.data['urls'] as Map?)?.cast<String, dynamic>();
    final url = urls?['vertical'] ?? urls?['landscape'];
    if (url == null) throw Exception('no url');
    return url as String;
  }

  /// Fetches the clip to a temp file (one name per match, so repeats
  /// overwrite rather than pile up). dart:io, no HTTP dependency.
  static Future<File> _downloadToTemp(String matchId) async {
    final url = await _fileUrl(matchId);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/bully_league_$matchId.mp4');
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw Exception('download failed (${resp.statusCode})');
      }
      await resp.pipe(file.openWrite());
      return file;
    } finally {
      client.close();
    }
  }

  /// Opens the OS share sheet with the video FILE attached - a file (not a
  /// link) is what lands the clip in the TikTok / Instagram composer, and the
  /// watermark is burned in so every share carries attribution. Returns an
  /// error message, or null on success (the share sheet is the feedback).
  static Future<String?> share(String matchId) async {
    try {
      final file = await _downloadToTemp(matchId);
      await Share.shareXFiles([
        XFile(file.path, mimeType: 'video/mp4'),
      ], text: shareText);
      return null;
    } on FirebaseFunctionsException catch (e) {
      return e.message ?? 'Your clip is not ready yet.';
    } catch (_) {
      return "Couldn't prepare the clip to share.";
    }
  }

  /// Saves the clip into the photo library, in a "The Bully League" album.
  static Future<ClipSaveResult> saveToPhotos(String matchId) async {
    try {
      if (!await Gal.hasAccess(toAlbum: true) &&
          !await Gal.requestAccess(toAlbum: true)) {
        return const ClipSaveResult(
          false,
          'Allow photo access in Settings to save clips to your phone.',
        );
      }
      final file = await _downloadToTemp(matchId);
      await Gal.putVideo(file.path, album: _album);
      return ClipSaveResult(
        true,
        defaultTargetPlatform == TargetPlatform.iOS
            ? 'Saved to your Photos.'
            : 'Saved to your gallery.',
      );
    } on FirebaseFunctionsException catch (e) {
      return ClipSaveResult(false, e.message ?? 'Your clip is not ready yet.');
    } on GalException catch (e) {
      return ClipSaveResult(
        false,
        e.type == GalExceptionType.accessDenied
            ? 'Allow photo access in Settings to save clips to your phone.'
            : e.type == GalExceptionType.notEnoughSpace
            ? 'Not enough space on your phone to save the clip.'
            : "Couldn't save the clip.",
      );
    } catch (_) {
      return const ClipSaveResult(false, "Couldn't save the clip.");
    }
  }
}

/// Full-screen in-app playback of the finished captioned clip, with Share
/// and Save right under it - the moment someone has just watched their clip
/// is the moment they want to post it, so they never have to back out to do
/// it (developer's call, 2026-11-08). Reuses the judge feed's looping
/// [MatchClipPlayer], so there is one player to maintain.
class _ClipPreviewScreen extends StatefulWidget {
  const _ClipPreviewScreen({required this.url, required this.matchId});

  final String url;
  final String matchId;

  @override
  State<_ClipPreviewScreen> createState() => _ClipPreviewScreenState();
}

class _ClipPreviewScreenState extends State<_ClipPreviewScreen> {
  bool _busy = false;

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    final failure = await ClipActions.share(widget.matchId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) _say(failure);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final result = await ClipActions.saveToPhotos(widget.matchId);
    if (!mounted) return;
    setState(() => _busy = false);
    _say(result.text);
  }

  @override
  Widget build(BuildContext context) {
    // Video takes all the space above a slim Share / Save row.
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Your clip'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(child: MatchClipPlayer(videoUrl: widget.url)),
            ),
            // Share / Save get their OWN row under the video (developer,
            // 2026-11-09: floating them over the clip covered the player's
            // scrubber and replay button on tall phones). Compact pills,
            // centred.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _OverlayButton(
                    icon: Icons.ios_share,
                    label: 'Share',
                    onPressed: _busy ? null : _share,
                  ),
                  const SizedBox(width: 10),
                  _OverlayButton(
                    icon: Icons.download_outlined,
                    label: ClipActions.saveLabel,
                    busy: _busy,
                    onPressed: _busy ? null : _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A translucent pill button that floats over video and stays readable on
/// any frame (dark glass + white text).
class _OverlayButton extends StatelessWidget {
  const _OverlayButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: Colors.black.withValues(alpha: 0.45),
        disabledBackgroundColor: Colors.black.withValues(alpha: 0.35),
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white70,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
        ),
      ),
    );
  }
}
