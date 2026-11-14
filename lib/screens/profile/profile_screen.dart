import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../core/badges/badges.dart';
import '../../core/emoji_ratings.dart';
import '../../core/social_links.dart';
import '../../core/streaks.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/push_notification_service.dart';
import '../../widgets/badges/badge_case.dart';
import '../../widgets/belt_flair.dart';
import '../../widgets/emoji_stats_card.dart';
import '../../widgets/home/player_status_card.dart';
import '../../widgets/home/rank_badges.dart';
import '../../widgets/social_links_editor.dart';
import '../account/delete_account_screen.dart';
import '../leaderboard/leaderboard_screen.dart';
import '../settings/account_screen.dart';
import '../vote/my_battles_screen.dart';
import 'emoji_scrub_sheet.dart';
import 'form_card.dart';
import 'intro_video_card.dart';
import 'selfie_card.dart';

const int kRequiredPhotoCount = 5;

/// Editable profile fields per CLAUDE.md's User Profile System - the
/// "ammo" a roaster gives opponents instead of relying purely on
/// appearance-based improv, plus the 5-photo requirement (Build Order
/// step 9a - deferred from step 7 specifically to land alongside visual
/// moderation, since accepting a photo without running it through
/// moderation first would violate CLAUDE.md's Content Policy & Moderation
/// section). Manual profile approval (approvalStatus) is a separate V1
/// admin workflow via the Firebase console, not enforced by this screen.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    this.embedded = false,
    this.promptIntro = false,
    this.isActiveTab = true,
  });

  /// False while this is the Profile tab and another tab is on screen. The
  /// tab shell keeps every tab loaded, so without this the intro video kept
  /// decoding in the background.
  final bool isActiveTab;

  /// True when shown as a bottom-nav tab.
  final bool embedded;

  /// True when a player was routed here from tapping battle without an intro
  /// video yet - shows a short "record this to battle" banner at the top so
  /// the requirement is obvious rather than something they have to hunt for.
  final bool promptIntro;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  // City & State (opponent-only) and an open "about me" box are all the text
  // the profile collects now - the intro video is the real ammo. (The old
  // profession/education/interests/relationship/pets/favoriteFood controllers
  // were removed 2026-10-17.)

  bool _loading = true;
  bool _saving = false;
  bool _signingOut = false;

  /// Listed unless explicitly opted out, mirroring the server's rule that
  /// only a literal `false` hides someone. Defaulting to hidden would
  /// leave the directory permanently empty for every existing account.
  bool _directoryListed = true;
  String? _statusMessage;
  List<String> _photoUrls = [];

  /// Read-only identity shown at the top of the screen. The username is
  /// deliberately NOT editable here (developer's call, 2026-09-14): a profile
  /// is where you see who you are, not where you are nudged to rename yourself.
  /// The backend setUsername still exists for signup, so this is reversible.
  String? _username;
  String? _rankTitle;

  /// The full user document, used for the badge case + featured badge.
  Map<String, dynamic>? _userData;

  DocumentReference<Map<String, dynamic>> get _userRef => FirebaseFirestore
      .instance
      .collection('users')
      .doc(FirebaseAuth.instance.currentUser!.uid);

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final snapshot = await _userRef.get();
    final data = snapshot.data();
    final profile = data?['profile'] as Map<String, dynamic>? ?? {};
    final photoUrls =
        (profile['photoUrls'] as List<dynamic>?)?.cast<String>() ?? [];
    final listed = data?['directoryListed'];
    final username = data?['username'] as String?;
    final rankTitle = data?['rankTitle'] as String?;
    if (mounted) {
      setState(() {
        _photoUrls = photoUrls;
        _directoryListed = listed != false;
        _username = username;
        _rankTitle = rankTitle;
        _userData = data;
        _loading = false;
      });
    }
  }

  /// Whether this player has any negative emoji ratings (🥱/💩) to clean up -
  /// gates the "Clean up bad ratings" action. Derived from the removable set,
  /// so a future negative emoji is covered automatically.
  bool get _hasNegativeRatings {
    final counts = (_userData?['emojiCounts'] as Map?)?.cast<String, dynamic>();
    for (final r in kRemovableEmojiRatings) {
      if (emojiCountOf(counts, r.key) > 0) return true;
    }
    return false;
  }

  /// Written immediately rather than waiting for Save. Someone switching
  /// this off wants to stop being findable now, not after they remember
  /// to press a button at the bottom of the screen.
  Future<void> _setDirectoryListed(bool value) async {
    setState(() {
      _directoryListed = value;
      _saving = true;
      _statusMessage = null;
    });
    try {
      await _userRef.update({'directoryListed': value});
      if (mounted) {
        setState(
          () => _statusMessage = value
              ? 'People can find you by name.'
              : 'You no longer appear in search.',
        );
      }
    } catch (e) {
      // Reverted on failure, so the switch never claims a state the
      // server does not have.
      if (mounted) {
        setState(() {
          _directoryListed = !value;
          _statusMessage = 'Could not change that. Try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _retakingSelfie = false;

  Future<void> _retakeSelfie() async {
    setState(() => _retakingSelfie = true);
    final result = await SelfieCard.capture(context);
    if (!mounted) return;
    setState(() => _retakingSelfie = false);
    if (result.cancelled) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? 'Photo updated.'
              : (result.reason ?? 'Could not update photo.'),
        ),
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// "215 pts · 🔥 1" for the detailed rank card.
  String _cardExtra() {
    final balance = (_userData?['pointsBalance'] as num? ?? 0).toInt();
    final days = liveJudgeStreakDays(_userData?['voteStreak']);
    return '$balance pts${days > 0 ? '  ·  🔥 $days' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    // Cinematic backstage background (developer's art, 2026-09-14), same
    // pattern as the Ranks and My Battles screens: a transparent Scaffold
    // over a fixed image with a dark base and a light scrim, so the profile
    // form scrolls over the "House Lights Down" venue art. fitWidth +
    // topCenter keeps the neon graffiti / stage at the top uncropped; the
    // dark floor of the image sits behind the lower settings rows.
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Your Profile'),
        automaticallyImplyLeading: !widget.embedded,
        // Account & settings (email, notifications, blocked players, sign
        // out) - moved here from Home's top-right avatar (2026-11-11).
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Account & settings',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
          ),
        ],
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Color(0xFF0E0B14))),
          Positioned.fill(
            child: Image.asset(
              'assets/home/profile_background.png',
              fit: BoxFit.fitWidth,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          // Light scrim for legibility. The form fields carry their own dark
          // fills, so this only has to lift white headings/labels off the
          // bright neon at the top and settle the lower rows into the dark
          // floor - a heavy scrim would wash out the art the developer chose.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x59000000),
                    Color(0x1F000000),
                    Color(0x73000000),
                  ],
                ),
              ),
            ),
          ),
          _loading
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(
                  child: SingleChildScrollView(
                    // Dragging the page closes the keyboard - iPhones have no
                    // Back key, so an open keyboard used to trap people here
                    // (beta tester, 2026-11-09).
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    // Content starts higher up (developer's call, 2026-09-29):
                    // the old kToolbarHeight+8 top pad pushed the identity/stats
                    // about 1/6 down the screen. The app bar is transparent and
                    // its "Your Profile" title is left-aligned, while the
                    // identity content is centred, so a small top pad lifts
                    // everything without the avatar colliding with the title.
                    padding: EdgeInsets.fromLTRB(
                      24,
                      12,
                      24,
                      24 + MediaQuery.of(context).padding.bottom,
                    ),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (widget.promptIntro) ...[
                            Card(
                              color: Theme.of(
                                context,
                              ).colorScheme.primaryContainer,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Before you unleash your trauma on a '
                                      'complete stranger, please…',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.copyWith(
                                            // A bright, vivid pink so the headline
                                            // actually invites reading - the muted
                                            // container colours were too flat.
                                            color: const Color(0xFFFF4D8D),
                                            fontWeight: FontWeight.bold,
                                            height: 1.15,
                                          ),
                                    ),
                                    const SizedBox(height: 10),
                                    const Text(
                                      'Record a quick intro video and take a selfie. '
                                      'Your opponent studies the intro for ammo and '
                                      'sees your face before the battle. Be honest — '
                                      'it makes the show more fun to watch.',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                        height: 1.3,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),
                            // Hoisted to the very top for onboarding: this is the
                            // thing they came here to do, so it should not be below
                            // the identity header and badge case where it has to be
                            // scrolled to.
                            IntroVideoCard(active: widget.isActiveTab),
                            const SizedBox(height: 24),
                            const SelfieCard(),
                            const SizedBox(height: 24),
                          ],
                          // The player's actual username as a heading, read-only
                          // (developer's call, 2026-09-14): the top of a profile is
                          // your identity, not a prompt to rename yourself. The
                          // change-username control and the "your form" stats card
                          // that used to sit here are gone; the referral bits moved
                          // down near settings, where occasional actions belong.
                          // Streams the user doc so the photo appears the moment a
                          // selfie is saved (the selfie card writes it directly, so
                          // the one-time profile load would otherwise keep showing
                          // the empty placeholder). The selfie IS the profile photo.
                          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                            stream: _userRef.snapshots(),
                            builder: (context, snap) {
                              final profile =
                                  snap.data?.data()?['profile']
                                      as Map<String, dynamic>?;
                              final photos = profile?['photoUrls'];
                              final photo =
                                  (profile?['facePhotoUrl'] as String?) ??
                                  (photos is List && photos.isNotEmpty
                                      ? photos.first as String?
                                      : null) ??
                                  (_photoUrls.isNotEmpty
                                      ? _photoUrls.first
                                      : null);
                              return _IdentityHeader(
                                username: _username,
                                // The detailed rank card right below shows the
                                // title, so the header only repeats it during
                                // onboarding (where the card is hidden).
                                rankTitle: widget.promptIntro
                                    ? _rankTitle
                                    : null,
                                photoUrl: photo,
                                onPhotoTap: _retakeSelfie,
                                photoBusy: _retakingSelfie,
                              );
                            },
                          ),
                          // The Belt (if you hold it) - the reigning Main Stage
                          // champion wears it on their own profile too. Renders
                          // nothing when you don't hold it.
                          if (FirebaseAuth.instance.currentUser != null) ...[
                            const SizedBox(height: 10),
                            Center(
                              child: BeltFlair(
                                uid: FirebaseAuth.instance.currentUser!.uid,
                              ),
                            ),
                          ],
                          // Career record strip - the "homebase" numbers that live
                          // nowhere else (Home shows XP + rank, not W-L). Hidden for a
                          // brand-new player with no history so a fresh profile stays
                          // clean.
                          // THE DETAILED RANK CARD (2026-11-11, option B): Home
                          // shows the compact card; the full one - crest, tier
                          // numeral, exact XP, points and streak - lives here.
                          if (!widget.promptIntro &&
                              FirebaseAuth.instance.currentUser != null) ...[
                            const SizedBox(height: 16),
                            PlayerStatusCard(
                              uid: FirebaseAuth.instance.currentUser!.uid,
                              fallbackTitle: _rankTitle,
                              horizontalMargin: 0,
                              extra: _cardExtra(),
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const LeaderboardScreen(),
                                ),
                              ),
                            ),
                          ],
                          if (!widget.promptIntro)
                            _CareerStats(user: _userData),
                          if (!widget.promptIntro) _Streaks(user: _userData),
                          // MY BATTLES moved inside Profile (2026-11-11 swipe
                          // layout): the last 3, then "See all".
                          if (!widget.promptIntro &&
                              FirebaseAuth.instance.currentUser != null) ...[
                            const SizedBox(height: 20),
                            RecentBattlesSection(
                              uid: FirebaseAuth.instance.currentUser!.uid,
                            ),
                          ],
                          const SizedBox(height: 24),
                          // Badges and the (normal-position) intro card only when NOT
                          // onboarding - in promptIntro mode the intro card is hoisted
                          // to the top and a brand-new player has no badges to show.
                          if (!widget.promptIntro) ...[
                            // The crowd/emoji cards (Crowd read + Crowd badges) sit
                            // ABOVE the Awards achievements - the developer's call, so
                            // "Crowd badges" reads above "Awards" while the emoji pair
                            // stays together.
                            EmojiStatsCard(
                              counts: (_userData?['emojiCounts'] as Map?)
                                  ?.cast<String, dynamic>(),
                            ),
                            // Spend points to shave down your negative ratings
                            // (🥱/💩). Shown only when there is something to clean up,
                            // on your OWN profile only (the sheet writes via a Cloud
                            // Function). A quiet secondary action, not a pitch.
                            if (_hasNegativeRatings) ...[
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed: () async {
                                    await EmojiScrubSheet.show(context);
                                    await _loadProfile();
                                  },
                                  icon: const Icon(
                                    Icons.cleaning_services,
                                    size: 16,
                                  ),
                                  label: const Text('Clean up bad ratings'),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.white.withValues(
                                      alpha: 0.6,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            BadgeCase(
                              stats: BadgeStats.fromUser(_userData),
                              earnedIds: resolveEarnedIds(_userData),
                            ),
                            const SizedBox(height: 28),
                            // The mandatory intro video sits above photos because it
                            // is the one profile item a player CANNOT battle without
                            // (enforced in enterQueue), and it is the ammo the
                            // opponent actually studies pre-match.
                            IntroVideoCard(active: widget.isActiveTab),
                            const SizedBox(height: 24),
                            // The selfie IS the profile photo at the top (tap
                            // it to retake), so this section only appears while
                            // there is no selfie yet - it's required to battle.
                            StreamBuilder<
                              DocumentSnapshot<Map<String, dynamic>>
                            >(
                              stream: _userRef.snapshots(),
                              builder: (context, snap) {
                                final face =
                                    (snap.data?.data()?['profile']
                                            as Map<
                                              String,
                                              dynamic
                                            >?)?['facePhotoUrl']
                                        as String?;
                                if (!snap.hasData ||
                                    (face != null && face.isNotEmpty)) {
                                  return const SizedBox.shrink();
                                }
                                return const Padding(
                                  padding: EdgeInsets.only(bottom: 24),
                                  child: SelfieCard(),
                                );
                              },
                            ),
                          ],
                          // The battle card (name, where you're from, about me)
                          // moved OUT of the profile (2026-11-14): it's set once in
                          // the ranked setup flow and edited in Settings > Battle
                          // card, so the profile is your stats and identity.
                          if (_statusMessage != null) ...[
                            Text(
                              _statusMessage!,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 16),
                          ],
                          const SizedBox(height: 28),
                          const Divider(),
                          const SizedBox(height: 8),
                          // Curated external links (socials / tickets) shown on the
                          // fame page - the payoff of being followed. Its own save,
                          // separate from the profile-field Save above.
                          SocialLinksEditor(
                            initialLinks: socialLinksOf(_userData),
                            onSaved: _loadProfile,
                          ),
                          const SizedBox(height: 16),
                          const Divider(),
                          const SizedBox(height: 8),
                          // Referral bits live down here, not at the top - inviting a
                          // friend and recording who invited you are occasional
                          // actions, not what a player opens their profile to do.
                          const InviteCard(),
                          const ReferrerField(),
                          const SizedBox(height: 8),
                          const Divider(),
                          // Sits with the profile because being findable is a
                          // property of the profile, and it is the one control
                          // here that affects who can reach you rather than
                          // what they see.
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _directoryListed,
                            onChanged: _saving ? null : _setDirectoryListed,
                            title: const Text('Let people find me by name'),
                            subtitle: const Text(
                              'Subscribers can search for your username and see '
                              'your photo and rank. Turn this off and you '
                              'stop appearing in search entirely.',
                            ),
                          ),
                          // Appearance and Blocked players deliberately live only in
                          // the Account hub (the Home avatar), not here - they were
                          // duplicated in both places. The profile keeps the controls
                          // that are properties of the profile itself.
                          const SizedBox(height: 24),
                          const Divider(),
                          const SizedBox(height: 12),
                          // Sign out lives here now, off the Home app bar where a
                          // one-tap logout was too easy to hit by accident. A
                          // deliberate action in the account area, but plainly
                          // findable (unlike delete, which is quieter still).
                          OutlinedButton.icon(
                            onPressed: _signingOut ? null : _signOut,
                            icon: const Icon(Icons.logout, size: 18),
                            label: const Text('Sign out'),
                          ),
                          const SizedBox(height: 8),
                          // CCPA requires a user-facing way to delete an account
                          // and its data (see CLAUDE.md's Compliance / Account
                          // Management item). Placed here because this is where
                          // a user's personal data lives, and kept visually
                          // quiet - it should be findable, not easy to hit by
                          // accident. The screen itself explains exactly what is
                          // deleted and what is kept before anything happens.
                          TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const DeleteAccountScreen(),
                              ),
                            ),
                            child: const Text(
                              'Delete my account',
                              style: TextStyle(color: Color(0xFFE05252)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  /// Drops this device's push token before signing out, so the next person
  /// to sign in here doesn't receive the previous account's match alerts.
  /// Best-effort: a failure to clean up the token must not trap someone in
  /// an account they're trying to leave, so sign-out proceeds regardless.
  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    final push = context.read<PushNotificationService>();
    final auth = context.read<AuthService>();
    try {
      await push.unregister();
    } catch (_) {
      // Intentionally ignored - see above.
    }
    await auth.signOut();
    // No setState after: signing out swaps this whole tree out via AuthGate.
  }
}

/// The read-only identity at the top of the profile: avatar, username and
/// rank title. The username is deliberately not editable here.
class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({
    this.username,
    this.rankTitle,
    this.photoUrl,
    this.onPhotoTap,
    this.photoBusy = false,
  });

  final String? username;
  final String? rankTitle;
  final String? photoUrl;

  /// Tapping the photo retakes the selfie - the photo lives here, not in a
  /// separate section further down the page.
  final VoidCallback? onPhotoTap;
  final bool photoBusy;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final name = (username != null && username!.isNotEmpty)
        ? username!
        : 'Your profile';
    // The two top tiers get a gold title (matching the Home status card) so the
    // most prestigious ranks read as prestige; lower tiers stay muted.
    final prestige = rankTitle == 'Legend' || rankTitle == 'GOAT';
    return Column(
      children: [
        GestureDetector(
          onTap: photoBusy ? null : onPhotoTap,
          child: Stack(
            children: [
              CircleAvatar(
                radius: 42,
                backgroundColor: scheme.surfaceContainerHighest,
                backgroundImage: photoUrl != null
                    ? NetworkImage(photoUrl!)
                    : null,
                child: photoBusy
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : photoUrl == null
                    ? Icon(
                        Icons.person,
                        size: 44,
                        color: scheme.onSurfaceVariant,
                      )
                    : null,
              ),
              if (onPhotoTap != null)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.surface, width: 2),
                    ),
                    child: Icon(
                      Icons.photo_camera,
                      size: 14,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          name,
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        if (rankTitle != null && rankTitle!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                rankTitle!,
                style: text.titleSmall?.copyWith(
                  color: prestige
                      ? const Color(0xFFF4C838)
                      : scheme.onSurfaceVariant,
                  fontWeight: prestige ? FontWeight.w800 : null,
                ),
              ),
              // The ladder rung as a Roman numeral ("· V"), matching Home.
              if (rankTierNumeral(rankTitle) != null) ...[
                Text(
                  '  ·  ',
                  style: text.titleSmall?.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
                Text(
                  rankTierNumeral(rankTitle)!,
                  style: text.titleSmall?.copyWith(
                    color: rankTierColor(rankTitle) ?? const Color(0xFFF4C838),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ],
          ),
        ],
        // The featured award used to sit here, but it duplicated the Awards
        // case listed just below (developer's call, 2026-09-29). Featuring
        // still matters - the featured award is shown to your OPPONENT in the
        // pre-match bio reveal - so the mechanism stays; only this redundant
        // top-of-own-profile copy is removed.
      ],
    );
  }
}

/// The career-record strip under the identity header: Record (W-L), Win rate,
/// and Battles judged. Deliberately the numbers NOT already headlined on Home
/// (which shows XP + rank) or in the badges (which show milestones, not a clean
/// total), so it complements rather than repeats. Free/ungated - W-L is already
/// public on the Ranks board. Renders nothing until the player has a history.
class _CareerStats extends StatelessWidget {
  const _CareerStats({required this.user});

  final Map<String, dynamic>? user;

  int _int(String key) => (user?[key] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final wins = _int('wins');
    final losses = _int('losses');
    final judged = _int('votesCast');
    // Nothing to show for a brand-new account - a row of zeros is noise.
    if (wins == 0 && losses == 0 && judged == 0) {
      return const SizedBox.shrink();
    }
    final decided = wins + losses;
    final winRate = decided > 0 ? '${(wins * 100 / decided).round()}%' : '—';

    // IntrinsicHeight bounds the Row's vertical extent to its children so the
    // full-height dividers work. WITHOUT it, CrossAxisAlignment.stretch inside
    // the profile's vertical SingleChildScrollView gets an UNBOUNDED height
    // constraint and the whole subtree fails to lay out SILENTLY (no red error)
    // - the exact "blanked the screen, no visible error" trap CLAUDE.md records
    // for the Home screen.
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: IntrinsicHeight(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _cell(context, '$wins–$losses', 'Record'),
            _divider(context),
            _cell(
              context,
              winRate,
              'Win rate',
              accent: const Color(0xFFF4C838),
            ),
            _divider(context),
            _cell(context, '$judged', 'Judged'),
          ],
        ),
      ),
    );
  }

  Widget _divider(BuildContext context) => Container(
    width: 1,
    margin: const EdgeInsets.symmetric(vertical: 4),
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4),
  );

  Widget _cell(
    BuildContext context,
    String value,
    String label, {
    Color? accent,
  }) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: text.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: accent ?? scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            style: text.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// The two streaks side by side (2026-11-11): JUDGING (daily - one vote a
/// day, and a day with nothing to judge still counts) and RANKED (weekly -
/// one ranked battle a week). Both always shown, so a 0 is a nudge to start.
class _Streaks extends StatelessWidget {
  const _Streaks({required this.user});

  final Map<String, dynamic>? user;

  @override
  Widget build(BuildContext context) {
    final judge = liveJudgeStreakDays(user?['voteStreak']);
    final ranked = liveRankedStreakWeeks(user?['rankedStreak']);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        children: [
          Expanded(
            child: _StreakChip(
              emoji: '🔥',
              value: judge,
              unit: judge == 1 ? 'day' : 'days',
              label: 'Judging streak',
              accent: const Color(0xFF2FE0A8),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StreakChip(
              emoji: '🎤',
              value: ranked,
              unit: ranked == 1 ? 'week' : 'weeks',
              label: 'Ranked streak',
              accent: const Color(0xFFB45CFF),
            ),
          ),
        ],
      ),
    );
  }
}

class _StreakChip extends StatelessWidget {
  const _StreakChip({
    required this.emoji,
    required this.value,
    required this.unit,
    required this.label,
    required this.accent,
  });

  final String emoji;
  final int value;
  final String unit;
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final live = value > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xCC0C0A14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: accent.withValues(alpha: live ? 0.7 : 0.25),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Opacity(
            opacity: live ? 1 : 0.4,
            child: Text(emoji, style: const TextStyle(fontSize: 24)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$value $unit',
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: live ? Colors.white : Colors.white54,
                  ),
                ),
                Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelSmall?.copyWith(
                    color: accent,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


