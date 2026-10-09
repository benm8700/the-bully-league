import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../theme/app_theme.dart';
import '../rewards/rewards_screen.dart';

import '../../core/services/auth_service.dart';
import '../../core/services/entitlement_service.dart';
import '../../core/services/matchmaking_service.dart';
import '../../widgets/admin_only.dart';
import '../../widgets/home/goat_throne_banner.dart';
import '../../widgets/home/prize_claim_banner.dart';
import '../../widgets/home/weekly_standing_banner.dart';
import '../../widgets/home/hero_mode_card.dart';
import '../../widgets/home/player_status_card.dart';
import '../../widgets/home/home_quick_actions.dart';
import '../../widgets/home/featured_section.dart';
import '../../widgets/event_window_banner.dart';
import '../match/bio_reveal_screen.dart';
import '../match/pre_match_screen.dart';
import '../match/recording_consent_screen.dart';
import '../tournament/climb_screen.dart';
import '../elite/elite_league_screen.dart';
import '../profile/profile_screen.dart';
import '../friends/challenge_screen.dart';
import '../practice/solo_practice_screen.dart';
import '../settings/account_screen.dart';
import '../settings/notification_settings_screen.dart';
import '../vote/finalize_test_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = context.read<AuthService>();

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        // The header logo is the WORDMARK-ONLY branding asset
        // (assets/branding/bully_league_wordmark.png) - the approved
        // bully_league_header.png with the "REAL PEOPLE. REAL ROASTS." tagline
        // cropped off (developer's call, 2026-09-14). The full header PNG is
        // kept in the repo untouched; this is a separate cropped file, so
        // restoring the tagline is a one-line asset-path change. Sized by
        // height only (BoxFit.contain preserves the aspect ratio - never
        // stretched, cropped or recoloured), kept compact.
        toolbarHeight: 72,
        titleSpacing: 16,
        title: Align(
          alignment: Alignment.centerLeft,
          child: Image.asset(
            'assets/branding/bully_league_wordmark.png',
            height: 44,
            fit: BoxFit.contain,
          ),
        ),
        actions: [
          // The bell shows notification settings (no badge count).
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            tooltip: 'Notifications',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const NotificationSettingsScreen(),
              ),
            ),
          ),
          // The profile avatar opens ACCOUNT & SETTINGS - deliberately NOT
          // the public Profile tab, which is the player's public identity.
          // (Sign out used to be a top-right one-tap button that a real user
          // hit by accident; it now lives one level in, inside Account.)
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 4),
            child: Tooltip(
              message: 'Account',
              child: InkResponse(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AccountScreen()),
                ),
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: scheme.surfaceContainerHighest,
                  child: Icon(Icons.person,
                      size: 18, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
        ],
      ),
      // Listens rather than reading currentUser once: right after sign-up,
      // the account is created (and this screen shown) before the
      // displayName update lands, so this needs to pick up that follow-up
      // update once it arrives instead of freezing on the first snapshot.
      body: StreamBuilder<User?>(
        stream: authService.authStateChanges(),
        initialData: authService.currentUser,
        builder: (context, snapshot) {
          final uid = snapshot.data?.uid;
          // Scrollable rather than a bare centred Column: Home has grown
          // past what a small screen can show at once (seen live as a
          // 156px overflow on a 320x640 device), and it will keep growing.
          // Centred only when there's room to spare, so it still looks
          // deliberate on a large phone rather than pinned to the top.
          // The system gesture/nav bar inset at the bottom. Without adding it
          // to the scroll padding, when the content height is close to the
          // viewport height (seen on the S22) the centred Column sits its
          // bottom items - the Find a Match CTA - flush against the nav bar
          // with no room to scroll clear of it.
          final bottomInset = MediaQuery.of(context).viewPadding.bottom;
          return LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: EdgeInsets.only(top: 16, bottom: 16 + bottomInset),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 32 - bottomInset,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // The Player Status card IS the identity block now - the
                    // old username greeting above it was redundant furniture
                    // (the name is on the card's trophy context and the
                    // header carries the brand), so it was removed in the
                    // 2026-09-14 Home overhaul to match the reference.
                    if (uid != null) _RankBadge(uid: uid),
                    // Tightened so the compact HUD sits closer to the Tournament
                    // hero, leaving a little more of Roast a Stranger visible.
                    const SizedBox(height: 12),
                    // Anything urgent stays at the very top: a match
                    // waiting, or somebody challenging you.
                    const _ActiveMatchBanner(),
                    const _ActiveGauntletBanner(),
                    const _IncomingChallengeBanner(),
                    const PrizeClaimBanner(),
                    // The "defend your throne" warning - shown only to a GOAT
                    // under threat or the challenger closing on their spot.
                    const GoatThroneBanner(),
                    const _TrialStatus(),
                    const SizedBox(height: 8),
                    // THE HEADLINE: Sixes and Sevens IS the nightly
                    // tournament (CLAUDE.md), so it leads - prestige and
                    // prizes live here, and it is where everyone is pointed
                    // first. Tapping it goes to the tournament, where
                    // check-in lives.
                    const EventWindowBanner(),
                    // One-line "where you stand this week" hook under the
                    // tournament banner, tapping through to the WEEKLY Ranks
                    // board. Renders nothing until a weekly race is live.
                    const WeeklyStandingBanner(),
                    const SizedBox(height: 12),
                    // Secondary hero: Roast a Stranger (play now). Illustrated
                    // red/blue VS artwork with the title, subtitle and FIND A
                    // MATCH CTA as Flutter overlays - distinct from the gold
                    // tournament hero above, with dark breathing room between.
                    RoastHero(
                      onFindMatch: () => _startMatch(context, 'ranked'),
                    ),
                    // The Elite League entry. Shown ONLY to Featured Talent
                    // + GOAT and renders nothing for everyone else (like
                    // FeaturedSection), so it never clutters Home for the
                    // players who can't enter - it is a reward you see
                    // appear when you reach the top.
                    if (uid != null) _EliteLeagueCard(uid: uid),
                    const SizedBox(height: 14),
                    // Quick Actions row (Home overhaul): Daily Challenges /
                    // Free Rewards / Current Streak. The Daily Challenges card
                    // opens the full quests in a sheet, so the tall inline
                    // quest list is no longer shown here (one route, not two).
                    if (uid != null) HomeQuickActions(uid: uid),
                    const SizedBox(height: 14),
                    // Slim wallet line: "N Points" + Rewards ->. The old
                    // milestone bar moved into the Rewards screen; Home keeps
                    // only the glanceable balance and a way in.
                    if (uid != null) _WalletBarForUser(uid: uid),
                    // Featured spotlight (promotional/comedian clips). Renders
                    // NOTHING at launch - there is no real featured content yet
                    // and an empty section would look broken. Intentionally
                    // kept; must not be removed. See FeaturedSection.
                    const FeaturedSection(),
                    const SizedBox(height: 24),
                    // Everything below is navigation rather than the
                    // day's business, and the rule says so without a
                    // heading nobody would read.
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32),
                      child: Divider(),
                    ),
                    const SizedBox(height: 20),
                    // Practice-vs-a-stranger (the `exhibition` matchmaking
                    // mode) is gone from Home, collapsed into SOLO practice
                    // (2026-08-31): less is better, and the two real draws are
                    // the nightly tournament and Roast Someone Now. Warming up
                    // is a solo activity anyway, and solo practice still lives
                    // where it is actually wanted - the matchmaking screen
                    // offers "Warm up solo instead" for the empty-queue case.
                    // Battle a friend leads the navigation trio now.
                    //
                    // Sits with the battle actions because it IS a way to
                    // start a battle - and with a thin pool it is the most
                    // reliable one there is.
                    const _BattleFriendCard(),
                    // Solo practice is no longer offered here - Home is for
                    // battling and the day's business, not warm-ups. It
                    // still lives where it is actually wanted: the
                    // matchmaking screen offers "Warm up solo instead" for
                    // the empty-queue case, which is its real job.
                    //
                    // Judging, My Battles, Ranks and Profile are bottom-nav
                    // destinations now (see MainShell), so they are
                    // deliberately not repeated here - a second route to
                    // the same screen just makes this list longer and the
                    // tabs look decorative.
                    AdminOnly(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const FinalizeTestScreen(),
                            ),
                          ),
                          child: const Text('Finalize Match (test)'),
                        ),
                      ),
                    ),
                    // "How it works" moved off Home into Account & Settings
                    // (the top-right profile icon), under the account/email.
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Recording consent -> camera/mic check -> matchmaking queue -> match.
///
/// Mode is chosen here and carried all the way through, because each mode
/// has its own matchmaking queue - an exhibition player is never paired
/// into a match that moves someone's rating.
///
/// Top-level rather than a method so both the exhibition button and the
/// Ranked unlock gate can start the flow without one reaching into the
/// other's widget.
Future<void> _startMatch(BuildContext context, String mode) async {
  // Asked FIRST, before anything that costs the player effort. Without
  // this a lapsed player sits through the tutorial gate, the recording
  // consent screen and the entire camera-and-mic check, and only then gets
  // turned away by the queue - the worst possible moment to say no, and it
  // reads as a bug rather than a price. The server still enforces; this
  // just turns a late refusal into an early offer.
  final entitlement = await EntitlementService().current();
  if (!context.mounted) return;
  if (!entitlement.allows(mode)) {
    await _showBlockedSheet(context, entitlement, mode);
    return;
  }

  // The forced practice round is GONE (developer's call, 2026-09-22): it
  // made capable people feel talked down to. The tutorial still exists as a
  // replayable practice round, reachable from Rules. What a player genuinely
  // must do before a ranked/tournament battle is record an intro video (the
  // ammo the opponent studies, and the enterQueue gate) - so if it's
  // missing, route them straight to their profile to record it and fill in a
  // few details, rather than letting them walk to the queue and be refused.
  if (!await _ensureIntroReady(context, mode)) return;
  if (!context.mounted) return;

  final consented = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => const RecordingConsentScreen()),
  );
  if (consented != true || !context.mounted) return;

  await Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => PreMatchScreen(mode: mode)));
}

/// Says where this player stands: how much trial is left, or what a
/// lapsed account still gets for free.
///
/// A trial only converts if people KNOW it is ending, so this is not
/// decoration - it is the mechanism. Equally, someone whose trial has
/// ended must be told what they still have (ranked, free, every night)
/// rather than just losing access and guessing why.
///
/// Renders NOTHING while enforcement is off, which is the current state:
/// counting down a trial that expires into no restriction at all would be
/// a threat the app has no intention of carrying out.
class _TrialStatus extends StatefulWidget {
  const _TrialStatus();

  @override
  State<_TrialStatus> createState() => _TrialStatusState();
}

class _TrialStatusState extends State<_TrialStatus> {
  Entitlement? _entitlement;

  @override
  void initState() {
    super.initState();
    EntitlementService().current().then((e) {
      if (mounted) setState(() => _entitlement = e);
    });
  }

  @override
  Widget build(BuildContext context) {
    final e = _entitlement;
    if (e == null || !e.enforced || e.state == 'subscriber') {
      return const SizedBox.shrink();
    }

    final windowName = e.windowName ?? 'the daily window';
    final daysLeft = e.trialDaysLeft;
    final String message;
    if (e.state == 'trial') {
      if (daysLeft == null) return const SizedBox.shrink();
      message = daysLeft <= 1
          ? 'Last day of full access. After that, the nightly $windowName '
              'tournament stays free.'
          : '$daysLeft days of full access left.';
    } else {
      message = e.inWindow
          ? '$windowName is live - jump in free right now.'
          : 'Join the nightly $windowName tournament free, every night.';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

/// Explains why a battle isn't available, and what to do instead.
///
/// Deliberately never a dead end. Practice being closed during the window
/// points at Ranked, which is free for everyone right then; being lapsed
/// outside the window points at the window, which is free tonight. Both
/// are real alternatives available today, not just a subscribe button - a
/// paywall with no free path is how an app teaches people to close it.
Future<void> _showBlockedSheet(
    BuildContext context, Entitlement entitlement, String mode) {
  final windowName = entitlement.windowName ?? 'the daily window';
  final practiceDuringWindow = mode != 'ranked' && entitlement.inWindow;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            practiceDuringWindow ? '$windowName is live' : 'Battle any time',
            style: Theme.of(sheetContext).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            entitlement.blockedMessage ??
                'The nightly $windowName tournament is free, every night. '
                    'Subscribe to battle whenever you like.',
            style: Theme.of(sheetContext).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          if (practiceDuringWindow)
            FilledButton(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                _startMatch(context, 'ranked');
              },
              child: const Text('Battle in the window instead'),
            )
          else ...[
            // THE HIGHEST-INTENT MOMENT IN THE APP for this offer: they
            // just tried to battle and were refused, so a day of anytime
            // battling is worth more to them right now than at any other
            // point. It is also the sample that makes the subscription
            // legible - you cannot want what you have never had.
            const _DayPassOffer(),
            FilledButton(
              // Still nothing to SELL - there is no IAP and no Play
              // Console account, so promising a purchase flow would be a
              // lie. Says plainly when they can play for free instead.
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: const Text('Got it'),
            ),
          ],
          const SizedBox(height: 8),
          // Always available, whatever the tier or the hour, because it
          // costs nothing to provide. It is what stops this sheet being a
          // dead end for someone who cannot battle right now.
          TextButton(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SoloPracticeScreen(),
                ),
              );
            },
            child: const Text('Warm up solo instead'),
          ),
          TextButton(
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );
}

/// Makes sure the player is battle-ready before a ranked or tournament match:
/// an approved intro video AND the four required profile fields filled in.
///
/// This replaced the forced practice round. Two things must exist before a
/// real battle: the intro video (the ammo the opponent studies, and the
/// enterQueue gate) and a filled-in profile (the developer's call after
/// players entered ranked with blank profiles - the opponent gets nothing to
/// work with). When either is missing we send the player to their profile to
/// complete it rather than letting them reach the queue and hit a late
/// refusal. Practice (exhibition) is exempt: it's the warm-up, and a
/// first-timer should be able to practise before they've recorded anything.
///
/// Fails OPEN: if the doc can't be read, the match proceeds and the server's
/// own enterQueue gate has the final say - a transient read shouldn't block
/// someone who is actually ready.
Future<bool> _ensureIntroReady(BuildContext context, String mode) async {
  if (mode == 'exhibition') return true;
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return true;
  try {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
    final profile = snap.data()?['profile'] as Map<String, dynamic>?;
    final introUrl = profile?['introVideoUrl'] as String?;
    final hasIntro = introUrl != null && introUrl.isNotEmpty;
    // The four fields ProfileScreen marks "Required" - the opponent's ammo.
    bool filled(String key) =>
        (profile?[key] as String?)?.trim().isNotEmpty ?? false;
    final hasProfile = filled('profession') &&
        filled('education') &&
        filled('hometown') &&
        filled('interests');
    if (hasIntro && hasProfile) return true;
  } catch (_) {
    return true;
  }
  if (!context.mounted) return false;
  // Take them straight to where they record the intro and fill the fields,
  // with a banner explaining why. They'll tap battle again once ready.
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const ProfileScreen(promptIntro: true)),
  );
  return false;
}

/// Shows the Laugh Meter (rank title + XP climb) and the win/loss record.
/// As of the XP ladder (2026-08-25) the title comes from career XP and the
/// Elo rating is hidden - it is not shown here or anywhere else.
///
/// Shows real progress rather than a silent unlock - that decision is
/// explicit, and a disabled button with no explanation reads as a bug.
/// The server enforces the gate regardless; this is the honest UI for it.
/// Shows a way back into a match the player was paired into but never
/// collected, and renders nothing at all when there isn't one.
///
/// This exists because of the match-found push: a player can be paired
/// while the app is backgrounded, and if the process was killed before
/// they came back, they'd otherwise land here with a live pairing they
/// have no route to. Their queue entry stays flagged "matched"
/// server-side precisely so it can be recovered (matched entries are
/// deliberately exempt from stale-entry pruning).
///
/// Re-checks on app resume as well as on first build, so tapping the
/// notification surfaces the banner even when the process was already
/// alive. Doubles as the in-app "match found" indicator CLAUDE.md asks
/// for alongside the push, though only in this recovery position - a
/// live indicator while queueing isn't built.
/// "Battle any time today for N points" - the points economy's recurring
/// sink, offered at the moment it is worth most.
///
/// WHY THIS SINK AND NOT MORE CLIPS. A clip is terminal: you want one, you
/// get it, and then you want nothing, so points go dead once someone has
/// covered the win they cared about. Access recurs - you want another next
/// week - so the grind never runs out of purpose. It is also the one thing
/// a free player most wants and cannot otherwise have, which makes
/// grinding for it a taste of the subscription rather than a substitute
/// for it.
///
/// Renders NOTHING unless a pass can actually be bought right now. An
/// offer someone cannot take is worse than no offer: it is a paywall with
/// a price tag they cannot reach, at the exact moment they were already
/// told no.
class _DayPassOffer extends StatefulWidget {
  const _DayPassOffer();

  @override
  State<_DayPassOffer> createState() => _DayPassOfferState();
}

class _DayPassOfferState extends State<_DayPassOffer> {
  Map<String, dynamic>? _state;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('getDayPassState')
          .call<Map<String, dynamic>>();
      if (mounted) setState(() => _state = r.data);
    } catch (_) {
      // Nothing rather than an error - the sheet still works without it.
    }
  }

  Future<void> _buy() async {
    setState(() => _busy = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('buyDayPass')
          .call<Map<String, dynamic>>();
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Day pass active. Battle whatever you like today.'),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not buy a pass.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (state == null) return const SizedBox.shrink();
    final price = (state['price'] as num?)?.toInt() ?? 0;
    final balance = (state['balance'] as num?)?.toInt() ?? 0;
    final text = Theme.of(context).textTheme;

    // Switched off entirely from config - show nothing at all, including
    // the "N more points" nudge, or we would be advertising something
    // nobody can ever buy.
    if (state['enabled'] == false) return const SizedBox.shrink();

    if (state['canBuy'] != true) {
      // Short of the price, we show the GAP rather than nothing, because a
      // visible target is the whole reason to keep earning. Already bought
      // or already running shows nothing - there is nothing to offer.
      if (state['active'] == true || state['boughtToday'] == true ||
          balance >= price) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          '${price - balance} more points and you could battle any time '
          'for a day.',
          style: text.bodySmall,
          textAlign: TextAlign.center,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.tonal(
            onPressed: _busy ? null : _buy,
            child: Text('Battle any time today - $price points'),
          ),
          const SizedBox(height: 4),
          Text(
            'You have $balance. One pass per day.',
            style: text.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// "X challenged you" on Home.
///
/// A challenge expires in an hour, so it has to be visible somewhere the
/// player already looks - the push can be missed, muted, or denied at the
/// permission prompt, and a challenge nobody notices is the same as one
/// never sent. Renders nothing when there is none, so it costs a
/// zero-height widget the rest of the time.
class _IncomingChallengeBanner extends StatefulWidget {
  const _IncomingChallengeBanner();

  @override
  State<_IncomingChallengeBanner> createState() =>
      _IncomingChallengeBannerState();
}

class _IncomingChallengeBannerState extends State<_IncomingChallengeBanner>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _challenge;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // POLL, not just load-once. This banner lives on Home, which sits in
    // MainShell's IndexedStack and is built ONCE at login - it never re-inits
    // when you switch tabs. So a challenge that arrives while you're already
    // in the app (foreground, on Home) was invisible until a full relaunch:
    // there's no resume event and no rebuild to trigger a reload, and the push
    // is best-effort (it may not fire at all). Found on a 2-device test
    // (2026-09-01). Friend battles are "battle now?", so the target has to see
    // it live. Mirrors the challenger's poll in challenge_screen.dart. Cheap at
    // beta scale - one callable every few seconds; revisit if it ever needs to
    // scale (a listener would be lighter, but challenges are callable-only).
    _poll = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-checked on resume too (e.g. tapping the push notification brings the
    // app forward); the poll above covers the already-foreground case.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('getMyChallenges')
          .call<Map<String, dynamic>>();
      final incoming = (r.data['incoming'] as List?) ?? const [];
      if (!mounted) return;
      setState(() => _challenge = incoming.isEmpty
          ? null
          : (incoming.first as Map).cast<String, dynamic>());
    } catch (_) {
      // Nothing rather than an error: a failed check must not make Home
      // look broken.
    }
  }

  @override
  Widget build(BuildContext context) {
    final challenge = _challenge;
    if (challenge == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${challenge['fromUsername']} challenged you',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ChallengeScreen()),
                );
                if (mounted) _load();
              },
              child: const Text('Answer'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveMatchBanner extends StatefulWidget {
  const _ActiveMatchBanner();

  @override
  State<_ActiveMatchBanner> createState() => _ActiveMatchBannerState();
}

class _ActiveMatchBannerState extends State<_ActiveMatchBanner>
    with WidgetsBindingObserver {
  final _service = MatchmakingService();
  MatchPairing? _pending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final pairing = await _service.activeMatch();
    if (!mounted) return;
    setState(() => _pending = pairing);
  }

  void _rejoin() {
    final pairing = _pending;
    if (pairing == null) return;
    setState(() => _pending = null);
    Navigator.of(context)
        .push(
          MaterialPageRoute(builder: (_) => BioRevealScreen(pairing: pairing)),
        )
        // The match may have ended while they were away, so re-check on
        // the way back rather than leaving a stale banner behind.
        .then((_) => _check());
  }

  @override
  Widget build(BuildContext context) {
    if (_pending == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              // Someone who left a standing challenge may have queued
              // hours ago and forgotten. "You have a match waiting" reads
              // as a bug to them; naming what happened reads as the thing
              // they actually asked for.
              Text(
                switch (_pending?.origin) {
                  'standing' => 'Someone took up your challenge',
                  'friend' => 'Your friend battle is waiting',
                  _ => 'You have a match waiting',
                },
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _rejoin,
                child: Text(
                  switch (_pending?.origin) {
                    'standing' => 'Battle now',
                    'friend' => 'Rejoin battle',
                    _ => 'Rejoin match',
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One-click return to a live gauntlet you backed out of or crashed during.
///
/// The matchmaking-queue banner above can't see the gauntlet (it runs off the
/// tournament doc, not the queue), so without this, leaving or crashing out of
/// the gauntlet stranded you on Home even though you were still in it.
/// Returning resumes the ClimbScreen poll, which routes you straight back into
/// your current battle if you have one. Re-checks on resume, like the other.
class _ActiveGauntletBanner extends StatefulWidget {
  const _ActiveGauntletBanner();

  @override
  State<_ActiveGauntletBanner> createState() => _ActiveGauntletBannerState();
}

class _ActiveGauntletBannerState extends State<_ActiveGauntletBanner>
    with WidgetsBindingObserver {
  final _service = MatchmakingService();
  ActiveGauntlet? _active;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final active = await _service.activeGauntlet();
    if (!mounted) return;
    setState(() => _active = active);
  }

  void _return() {
    final active = _active;
    if (active == null) return;
    setState(() => _active = null);
    Navigator.of(context)
        .push(MaterialPageRoute(
          // Consent was given on first entry; the ClimbScreen only re-prompts
          // as a fallback if it somehow arrives unconsented.
          builder: (_) => ClimbScreen(
            tournamentId: active.tournamentId,
            name: active.name,
            consented: true,
          ),
        ))
        .then((_) => _check());
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    if (active == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        color: context.palette.reward.withValues(alpha: 0.18),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.palette.reward.withValues(alpha: 0.6)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(Icons.emoji_events, color: context.palette.reward),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      active.inMatch
                          ? "You're in a gauntlet battle - get back in"
                          : "You're still in the gauntlet",
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: scheme.onSurface),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _return,
                  icon: const Icon(Icons.replay),
                  label: Text(active.inMatch
                      ? 'Rejoin your battle'
                      : 'Return to the gauntlet'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: userRef.snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }
        final data = snapshot.data!.data()!;
        // Handed to the card so a failed or slow meter/rank query still
        // shows who the player is. This document is already streamed here.
        final rankTitle = data['rankTitle'] as String?;
        final points = data['points'] as num?;

        // The Home overhaul (2026-09-14) replaced the tap-to-flip
        // collectible card with a single horizontal PLAYER STATUS card:
        // tier + rank badge + XP progress on the left, GLOBAL RANK on the
        // right. This shows numbers (XP and position), a deliberate
        // softening of the hidden-criteria rule - the developer's call to
        // match the reference. The card degrades to the fallback title if
        // the meter/rank queries fail, so the identity never disappears.
        return PlayerStatusCard(
          uid: uid,
          fallbackTitle: rankTitle,
          fallbackPoints: points,
        );
      },
    );
  }
}

/// Streams the user's spendable balance for the Home wallet line.
class _WalletBarForUser extends StatelessWidget {
  const _WalletBarForUser({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        if (data == null) return const SizedBox.shrink();
        final balance =
            ((data['pointsBalance'] ?? data['points']) as num?)?.toInt() ?? 0;
        return _WalletBar(balance: balance);
      },
    );
  }
}

/// The Elite League entry, shown ONLY to Featured Talent + GOAT.
///
/// Renders nothing for everyone else - not a locked/greyed teaser, nothing
/// at all - so Home stays clean for the players who can't enter and the
/// card simply APPEARS the day you reach the top, which is the reward.
/// Eligibility is checked here as a convenience; the real gate is
/// server-side in matchmaking.js (ELITE_RANK_TITLES), the source of truth.
class _EliteLeagueCard extends StatelessWidget {
  const _EliteLeagueCard({required this.uid});

  final String uid;

  // Mirrors the server's ELITE_RANK_TITLES. Kept in sync by hand (two
  // strings); the server enforces regardless of what the client shows.
  static const _eligible = {'Featured Talent', 'GOAT'};
  static const _gold = Color(0xFFF4C838);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots(),
      builder: (context, snapshot) {
        final rankTitle = snapshot.data?.data()?['rankTitle'] as String?;
        if (rankTitle == null || !_eligible.contains(rankTitle)) {
          return const SizedBox.shrink();
        }
        final text = Theme.of(context).textTheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const EliteLeagueScreen()),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    colors: [
                      _gold.withValues(alpha: 0.18),
                      _gold.withValues(alpha: 0.05),
                    ],
                  ),
                  border: Border.all(color: _gold.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.emoji_events_rounded,
                        color: _gold, size: 30),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('ELITE LEAGUE',
                              style: text.titleMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                              )),
                          const SizedBox(height: 2),
                          Text('Featured Talent & GOAT only · 2x20',
                              style: text.bodySmall?.copyWith(
                                color: _gold.withValues(alpha: 0.9),
                              )),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: _gold),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A slim wallet line: "N Points" on the left, "Rewards ->" on the right.
///
/// The whole strip taps through to the Rewards screen, where the milestone
/// list and redemption now live (the old Home milestone bar moved there).
class _WalletBar extends StatelessWidget {
  const _WalletBar({required this.balance});

  final int balance;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final gold = context.palette.currency;
    final accent = context.palette.accent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const RewardsScreen()),
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outlineVariant),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.monetization_on, color: gold, size: 18),
                const SizedBox(width: 7),
                Text(
                  '$balance',
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: gold,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  'Points',
                  style: text.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const Spacer(),
                Text(
                  'Rewards',
                  style: text.labelLarge?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.arrow_forward, color: accent, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Battle a Friend - a SECONDARY mode, so a compact premium PURPLE card
/// (identity/secondary colour per the app's colour hierarchy) that is quieter
/// than the gold Tournament banner and the pink Roast a Stranger hero, but
/// more premium than a plain outlined button. The whole card is tappable.
class _BattleFriendCard extends StatelessWidget {
  const _BattleFriendCard();

  static const Color _violet = Color(0xFFC08CEE);
  static const Color _border = Color(0xFF9A4FD0);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ChallengeScreen()),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              // Subtle plum illumination top-left into near-black navy.
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF241A33), Color(0xFF100C18)],
              ),
              border: Border.all(color: _border.withValues(alpha: 0.5)),
              boxShadow: [
                // Very restrained purple perimeter glow.
                BoxShadow(
                  color: _border.withValues(alpha: 0.16),
                  blurRadius: 16,
                  spreadRadius: -5,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  const _DuelIcon(),
                  const SizedBox(width: 12),
                  Container(
                    width: 1,
                    height: 34,
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'BATTLE A FRIEND',
                          style: text.titleSmall?.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Challenge someone you know',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            fontSize: 11.5,
                            color: const Color(0xFFA79FB2),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: _violet.withValues(alpha: 0.75),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact purple "two people + microphone" mark for Battle a Friend:
/// two-person silhouette with a small mic sitting between/below them, so it
/// reads immediately as "play against someone you know."
class _DuelIcon extends StatelessWidget {
  const _DuelIcon();

  static const Color _violet = Color(0xFFC08CEE);
  static const Color _micViolet = Color(0xFFDBBAF6);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 30,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // Two people, lifted a little so the mic tucks in below them.
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Icon(Icons.people_alt, color: _violet, size: 25),
          ),
          // The competitive element: a small mic between/near them, on a dark
          // disc so it stays legible against the silhouettes.
          Positioned(
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Color(0xFF140F1E),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.mic, color: _micViolet, size: 12),
            ),
          ),
        ],
      ),
    );
  }
}


