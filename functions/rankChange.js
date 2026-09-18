const {RANK_TIERS, GOAT_TITLE} = require("./rating");

/**
 * What to say when someone's rank changes.
 *
 * CLAUDE.md asks for a celebratory-or-roasting line specific to the
 * transition rather than a generic "you ranked up", with direction-
 * specific tone: up should feel earned and a little cocky, down should be
 * a playful roast rather than something discouraging. This is a roast
 * app - a demotion that reads like a sympathy card would be off-brand,
 * and one that reads like genuine discouragement would cost a player.
 *
 * KEYED ON THE DESTINATION RANK PLUS DIRECTION, not on the specific pair.
 * The doc's examples are written as pairs, but a rating swing can skip a
 * tier, and pairs would need ~90 entries to cover that - most of which
 * nobody would ever see, while the ones that DID fire would be the
 * unwritten ones. Twenty lines cover every possible transition, including
 * skips, and each is still specific to where you landed.
 */

/**
 * ONE LINE PER EARNED RANK, plus a single GOAT and GOAT-displaced line
 * (developer's copy, 2026-09-17). Variants were dropped once we realised XP
 * is monotonic: each earned rank fires exactly ONCE per player (you cross it
 * and never drop back below it), so a single player only ever sees one line
 * anyway - the "avoid repetition" reason for multiple variants never applied
 * to the earned ranks. GOAT can repeat (it is a live top-5 slot), but the
 * developer chose one line there too.
 *
 * THE TONE IS A DELIBERATE ARC: the low ranks get roasted, and as players
 * climb the app turns into their hype-man ("you still suck" -> "we're pulling
 * for you" -> a personal note from the founder). This positions the app as
 * the launchpad to fame, which is the core pitch.
 *
 * The rank NAME is not repeated in the line - the popup headline
 * ("Congratulations! You achieved the rank of X") already says it, so each
 * line is pure flavour.
 */

/** Arriving at a rank, having climbed to it. One line each. */
const UP = {
  // Never actually fires: Average Joe is the floor and a brand-new account's
  // first title is recorded silently. Kept only as a harmless fallback.
  "Average Joe": "Not an insult, exactly. Not a compliment either.",
  "Open Micer": "You still suck.",
  "Class Clown": "No one cares.",
  "The Funny Friend": "A few people think you're funny. So what?",
  "Door Guy": "You've piqued our interest.",
  "Regular":
    "You're seriously crushing this. Please stick around - we'd love to see more.",
  "Headliner":
    "You've got some real fuckin' talent. We'll be watching your next match.",
  "Legend":
    "You're the absolute shit. Remember us when you're famous - we're pulling for you.",
  "Featured Talent":
    "From all of us at The Bully League - and me personally, the founder - " +
    "you've genuinely impressed me. Your skill and your grind. I've got " +
    "something special for you.",
  [GOAT_TITLE]:
    "You're now one of the top 5 talent in the entire League. Only five " +
    "players can hold this title. If a challenger surpasses you, you'll have " +
    "to defend it in a title fight.",
};

/**
 * Falling to a rank. DORMANT among the earned ranks: XP is monotonic so no
 * earned rank is ever lost, and losing GOAT is handled by GOAT_DISPLACED
 * below - so nothing here actually fires today. Kept as one-line fallbacks in
 * case the ladder is ever made losable.
 */
const DOWN = {
  "Average Joe": "All the way back to Average Joe. The scenic route down.",
  "Open Micer": "Back to the open mic. The signup sheet missed you.",
  "Class Clown": "Back to Class Clown. A smaller room now.",
  "The Funny Friend": "The Funny Friend again. Beloved locally, unranked everywhere else.",
  "Door Guy": "Back on the door. At least you're still in the building.",
  "Regular": "Back to Regular. You kept the spot, you lost the billing.",
  "Headliner": "Bumped down to Headliner. Still the main event, technically.",
  "Legend": "Still a Legend. Just no longer the headline name.",
  "Featured Talent": "Back among the best, rather than above them.",
  [GOAT_TITLE]: "Still top five. Still insufferable.",
};

/**
 * Losing GOAT - the developer's line (2026-09-17). It reads as an honest
 * defeat ("you've been bested"), which fits the intended GOAT title-fight
 * mechanic (see CLAUDE.md): you lose the throne by losing a fight, not by an
 * invisible rating tick.
 */
const GOAT_DISPLACED =
  "You've been bested. But don't lose hope - hone your skills, return, and " +
  "take your status back!";

const ORDER = [...RANK_TIERS.map((t) => t.title), GOAT_TITLE];

/** Position on the ladder, or -1 for anything unrecognised. */
function rankIndex(title) {
  return ORDER.indexOf(title);
}

/**
 * The rank change to announce, or null if there is nothing to say.
 *
 * Pure, so the whole copy table is testable without Firestore.
 *
 * Returns null rather than a neutral message when nothing changed, when
 * either title is unrecognised, or when there is no previous title at all.
 * That last case is deliberate: a brand-new account has no
 * lastSeenRankTitle, and greeting someone with "you have been promoted to
 * Average Joe" for merely existing devalues every real promotion after it.
 */
function rankChangeFor(previousTitle, currentTitle,
    {displacedFromGoat = false} = {}) {
  if (!previousTitle || !currentTitle) return null;
  if (previousTitle === currentTitle) return null;

  const from = rankIndex(previousTitle);
  const to = rankIndex(currentTitle);
  if (from < 0 || to < 0) return null;

  const up = to > from;
  if (!up && previousTitle === GOAT_TITLE && displacedFromGoat) {
    return {
      direction: "down",
      from: previousTitle,
      to: currentTitle,
      title: `No longer ${GOAT_TITLE}`,
      message: GOAT_DISPLACED,
      displaced: true,
    };
  }

  return {
    direction: up ? "up" : "down",
    from: previousTitle,
    to: currentTitle,
    // The headline is the consistent template that names the rank; the
    // message below is pure flavour (developer's arc: roast low, hype high).
    title: up ?
      `Congratulations! You achieved the rank of ${currentTitle}` :
      `You dropped to ${currentTitle}`,
    message: (up ? UP : DOWN)[currentTitle] ?? null,
    displaced: false,
  };
}

/**
 * Pushes a rank change to whoever it happened to.
 *
 * CALLED ONCE, AFTER the GOAT sync rather than at each site that writes a
 * rank title. A single finalize can move someone Regular -> Headliner via
 * the base computation and then Headliner -> GOAT via the leaderboard
 * sync; notifying at both sites would send two pushes for what the player
 * experiences as one promotion. Comparing against the last title we
 * ANNOUNCED coalesces that into the one thing that actually happened.
 *
 * `lastNotifiedRankTitle` is deliberately separate from
 * `lastSeenRankTitle`, which the client uses for the in-app popup. They
 * legitimately differ - the push goes out while the app is closed, and
 * the popup waits until it is next opened - and sharing one field would
 * mean the push silently swallowed the popup.
 *
 * Best-effort throughout: a failed notification must never fail a match
 * finalization, which is the thing that actually moves rating.
 */
async function notifyRankChanges(uids, {displacedFromGoat = []} = {}) {
  if (!uids || uids.length === 0) return {sent: 0};
  const {getFirestore} = require("firebase-admin/firestore");
  const {sendToUsers} = require("./notifications");
  const db = getFirestore();
  const displaced = new Set(displacedFromGoat);

  let sent = 0;
  for (const uid of new Set(uids)) {
    try {
      const ref = db.collection("users").doc(uid);
      const snap = await ref.get();
      if (!snap.exists) continue;
      const user = snap.data();
      const change = rankChangeFor(
          user.lastNotifiedRankTitle, user.rankTitle,
          {displacedFromGoat: displaced.has(uid)});
      if (!change) {
        // Still record the current title, so a player whose rank moved
        // before this feature existed does not get an announcement for a
        // change they already lived through.
        if (user.lastNotifiedRankTitle !== user.rankTitle && user.rankTitle) {
          await ref.update({lastNotifiedRankTitle: user.rankTitle});
        }
        continue;
      }
      // Claimed BEFORE sending. Missing one announcement costs a moment;
      // repeating it is how an app gets muted at the OS level, which
      // silences every category and cannot be undone from inside.
      await ref.update({lastNotifiedRankTitle: user.rankTitle});
      const result = await sendToUsers([snap], {
        title: change.title,
        body: change.message,
        category: "rank_change",
        data: {kind: "rank_change", direction: change.direction},
      });
      sent += result?.sent ?? 0;
    } catch (e) {
      console.error(`rank change notify for ${uid} failed:`, e.message);
    }
  }
  return {sent};
}

/**
 * The rank change this player has not been shown in-app yet, if any.
 *
 * SERVED RATHER THAN COMPUTED CLIENT-SIDE, deliberately. The obvious
 * alternative is to let the app compare the two fields itself, but that
 * needs the ladder ORDER to decide up from down and the twenty lines of
 * copy to say anything - both duplicated, both able to drift. The first
 * attempt at that did drift immediately: the hand-copied order omitted
 * Headliner, which would have called a promotion a demotion for anyone
 * near it. One source, fetched.
 *
 * Marks the change as seen as part of answering, so it fires exactly
 * once. Reading it is inherently consuming it, which is why this is a
 * callable rather than a plain document read.
 */
async function getPendingRankChange(auth) {
  const {HttpsError} = require("firebase-functions/v2/https");
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {getFirestore} = require("firebase-admin/firestore");
  const ref = getFirestore().collection("users").doc(auth.uid);
  const snap = await ref.get();
  const user = snap.data();
  if (!user?.rankTitle) return {change: null};

  const seen = user.lastSeenRankTitle;
  // A brand-new account has never seen a rank. Recorded silently rather
  // than announced, so "you are now Average Joe" never fires for merely
  // signing up and devalues every real promotion after it.
  if (!seen) {
    await ref.update({lastSeenRankTitle: user.rankTitle});
    return {change: null};
  }
  if (seen === user.rankTitle) return {change: null};

  const change = rankChangeFor(seen, user.rankTitle);
  // Marked seen BEFORE returning. A popup that reappears every launch
  // because the write was skipped is far worse than one missed
  // celebration.
  await ref.update({lastSeenRankTitle: user.rankTitle});
  return {change};
}

module.exports = {
  rankChangeFor, rankIndex, notifyRankChanges, getPendingRankChange,
  UP, DOWN, GOAT_DISPLACED, ORDER,
};
