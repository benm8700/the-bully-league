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

/** Arriving at a rank, having climbed to it. */
const UP = {
  "Average Joe": "You clawed your way back to average. We are as surprised as you are.",
  "Open Micer": "You bombed less than usual. Welcome to Open Mic Night.",
  "Class Clown": "Funniest person in a room of people who are not funny. Class Clown.",
  "The Funny Friend": "Every group has one. Yours is now officially you.",
  "Door Guy": "They are letting you work the door. Try not to let it go to your head.",
  "Regular": "You are on the schedule now. Regular.",
  "Headliner": "Congrats, you are the main event now.",
  "Legend": "People are quoting you back to each other. Legend.",
  "Hall of Famer": "They will show your clips to people who were not even there.",
  [GOAT_TITLE]: "Do not let this go to your head, but you are funnier than everyone else.",
};

/** Falling to a rank, having dropped into it. */
const DOWN = {
  "Average Joe": "Wow, you are awful. Maybe it is time to find a new hobby.",
  "Open Micer": "Back to the open mic. The signup sheet missed you.",
  "Class Clown": "Back to Class Clown. The bar was on the floor and you found a basement.",
  "The Funny Friend": "You are the friend who is funny again. For a group of four.",
  "Door Guy": "Back on the door. At least you are still in the building.",
  "Regular": "Regular again. Still on the schedule, just not on the poster.",
  "Headliner": "Bumped down to Headliner. Still the main event, technically.",
  "Legend": "Legend only. The Hall can wait.",
  "Hall of Famer": "Out of the top five and back into the Hall.",
  [GOAT_TITLE]: "Somehow you are still the GOAT. Nobody is happy about it.",
};

/**
 * Losing GOAT is a special case and must be said honestly.
 *
 * GOAT is the ONE rank that is a live leaderboard position rather than a
 * threshold, so it can be lost without losing a single match - a sixth
 * player simply passes you. Telling someone they got worse when they did
 * not is both untrue and the kind of thing that makes a ranking system
 * feel rigged.
 */
const GOAT_DISPLACED =
  "You did not get worse. Someone else got better. You are out of the top five.";

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
function rankChangeFor(previousTitle, currentTitle, {displacedFromGoat = false} = {}) {
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
    title: up ? `You are now ${currentTitle}` : `You dropped to ${currentTitle}`,
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
