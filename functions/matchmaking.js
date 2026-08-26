const {getDatabase} = require("firebase-admin/database");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const {wantsCategory} = require("./notifications");
const {HttpsError} = require("firebase-functions/v2/https");
const {sanitiseQualityReport} = require("./captureQuality");
const {STARTING_RATING, RANK_TIERS} = require("./rating");
const {getMatchSettings} = require("./matchSettings");
const {readEventWindowConfig, qualifiesForWindow} = require("./eventWindow");
const {readMonetizationConfig, battleEntitlement, toMillis} = require("./entitlement");
const {shouldBecomeStanding, isLive} = require("./standingChallenge");
const {stopRecording, writeRecordingState} = require("./cloudRecording");

/** CLAUDE.md's recording scope decision: only ranked and tournament
 * matches are recorded and eligible for the highlight pipeline.
 * Exhibition matches are casual, don't move rating, and are never posted,
 * so they're never recorded - which also keeps the per-match recording
 * cost off the mode people play most casually. */
// "friend" is here on purpose despite not affecting rating: CLAUDE.md
// makes friend battles an explicit EXCEPTION to "exhibition is never
// recorded", because being recorded, judged and clipped is precisely what
// distinguishes a friend battle from a video call. Two separate questions,
// answered differently: does it move rating (no), and does it produce
// something (yes).
const RECORDED_MODES = ["ranked", "tournament", "friend"];

/**
 * Real matchmaking (Build Order step 4's missing half). Replaces the
 * hardcoded "test-channel" both devices used to join - see CLAUDE.md's
 * Build Order step 4 status note, which flagged "no real matchmaking
 * either" as the main gap.
 *
 * WHERE THE QUEUE LIVES: Firebase Realtime Database, per CLAUDE.md's
 * Matchmaking Queue Architecture decision (Firestore stays the store of
 * record for everything durable; RTDB holds only this ephemeral
 * "who's waiting right now" state).
 *
 * HOW CLIENTS INTERACT: only through the three callables below - clients
 * never read or write the queue directly, and RTDB rules deny all client
 * access to it (database.rules.json). That matters because a queue entry
 * carries the player's real rating and tier: if the client wrote its own
 * entry, a modified client could claim any rating it liked and hand-pick
 * its opponents. Same "sensitive writes go through Cloud Functions"
 * pattern as rating/points per CLAUDE.md's Security & Compliance Baseline.
 *
 * WHY POLLING, NOT AN RTDB LISTENER: the client calls pollMatchmaking on
 * an interval rather than subscribing to its own queue node. Two reasons:
 * (a) the tier-widening rule below is time-based, so *something* has to
 * re-attempt pairing periodically regardless - polling makes that the same
 * mechanism instead of a second one; (b) it keeps firebase_database off
 * the Flutter side entirely, which avoids adding another Android
 * dependency to a toolchain CLAUDE.md documents as fragile (the AGP pin,
 * the permission_handler/image_picker conflicts). The tradeoff is one
 * function invocation per waiting client every few seconds - fine at
 * private-beta volume, and the natural upgrade if that ever gets
 * expensive is an RTDB listener on the client's own node for the
 * *notification*, keeping these callables for the pairing itself.
 */

const MODES = ["exhibition", "ranked"];

/** Every 30s of waiting widens the acceptable tier gap by one, per
 * CLAUDE.md's matchmaking fallback decision ("gradually widen the tier
 * search range further over time... rather than waiting indefinitely or
 * falling back to a truly unrestricted match"). Band 0 = same tier only,
 * band 1 = ±1 tier, and so on - so it starts strict and eventually
 * matches anyone rather than leaving someone queued forever. */
const TIER_WIDEN_INTERVAL_MS = 30 * 1000;

/** CLAUDE.md's repeat-opponent cooldown: 1 day ideal, but "if no other
 * opponent is available, they can still be matched again sooner" -
 * availability takes priority over the cooldown when the pool is small.
 * Implemented as a preference below, not a hard filter. */
const REPEAT_OPPONENT_COOLDOWN_MS = 24 * 60 * 60 * 1000;

/** A client that crashes or is force-killed leaves its entry behind.
 * Anything older than this is treated as abandoned and pruned, so dead
 * entries can't be paired against (which would strand a live player in a
 * match nobody joins). */
const STALE_ENTRY_MS = 10 * 60 * 1000;

/**
 * A skill band for tier-proximity matchmaking, computed from the HIDDEN
 * Elo rating - NOT from the visible rank title.
 *
 * As of the XP ladder (2026-08-25) the title reflects accumulated XP, not
 * skill, so pairing by title would match a dedicated grinder against a
 * genuine expert. Elo is precisely the number kept hidden so it can still
 * run matchmaking, so this bands directly on it using the rating
 * thresholds in RANK_TIERS. GOAT needs no special case: a GOAT is top-5 by
 * rating, so their rating already lands them in the top band.
 */
function tierIndexFor(user) {
  const rating = Number.isFinite(Number(user.rating)) ?
    Number(user.rating) : STARTING_RATING;
  let idx = 0;
  for (let i = 0; i < RANK_TIERS.length; i++) {
    if (rating >= RANK_TIERS[i].minRating) idx = i;
  }
  return idx;
}

function queueRef(mode) {
  return getDatabase().ref(`matchmakingQueue/${mode}`);
}

/**
 * The earlier of the two players' queue-entry times, which is the one the
 * window determination should be judged against. Whoever was waiting first
 * is the one the pairing latency actually cost.
 *
 * Both players always get the same answer, since it's one field on one
 * shared document - a match where one side counted and the other didn't
 * would be indefensible.
 *
 * Pure and exported so the choice is testable without RTDB.
 */
function earliestQueuedAt(pairing) {
  // Only genuine numbers, and only positive ones. Number(null) is 0 and
  // Number("") is 0, both of which are finite - so a coercing filter would
  // let a MISSING opponent time win the Math.min as an epoch timestamp,
  // placing the match in 1970 and silently denying a bonus that was
  // legitimately earned. Caught by a test rather than in production.
  const times = [pairing?.joinedAt, pairing?.opponentJoinedAt]
      .filter((t) => typeof t === "number" && Number.isFinite(t) && t > 0);
  return times.length > 0 ? Math.min(...times) : NaN;
}

/**
 * The prime-time-window determination to stamp on a new match.
 *
 * Best-effort: if the config can't be read, the match proceeds as a
 * non-window match rather than failing the pairing. A missed bonus is a
 * disappointment; a failed pairing is a broken app.
 */
async function resolveEventWindow(pairedAtMs, queuedAtMs) {
  try {
    const snap = await getFirestore().collection("config").doc("eventWindow").get();
    const config = readEventWindowConfig(snap.data());
    const qualified = qualifiesForWindow({
      pairedAtMs,
      queuedAtMs,
      config,
    });
    return {qualified, name: config.name};
  } catch (e) {
    console.error("resolveEventWindow failed:", e.message);
    return {qualified: false, name: null};
  }
}

/**
 * The fixed Agora uid a player joins the match channel with: player1 is
 * always 1, player2 always 2.
 *
 * Clients used to join with the wildcard uid 0 and let Agora assign one
 * dynamically. That has to stop, because the recording layout has to name
 * each player's region by uid and the server has no way of learning a
 * dynamically-assigned one. Confirmed necessary by looking at real output:
 * Agora's "best fit" layout tiles participants side by side regardless of
 * canvas shape, which on a 9:16 canvas gives each player a narrow
 * half-width column instead of the stacked pair short-form video needs.
 *
 * The token is unaffected - it's minted against uid 0, which Agora treats
 * as a wildcard valid for any uid.
 */
const PLAYER1_AGORA_UID = 1;
const PLAYER2_AGORA_UID = 2;

function agoraUidFor(match, uid) {
  if (!match) return null;
  return uid === match.player1Id ? PLAYER1_AGORA_UID : PLAYER2_AGORA_UID;
}

function assertMode(mode) {
  if (!MODES.includes(mode)) {
    throw new HttpsError("invalid-argument", `mode must be one of: ${MODES.join(", ")}`);
  }
}

/**
 * Joins the queue. The entry is built here from the caller's REAL user
 * document rather than from anything the client sent, so rating, tier,
 * and block list can't be spoofed to farm favourable pairings.
 */
async function enterQueue(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const mode = data?.mode;
  assertMode(mode);

  const userSnap = await getFirestore().collection("users").doc(auth.uid).get();
  if (!userSnap.exists) {
    throw new HttpsError("failed-precondition", "No user profile found.");
  }
  const user = userSnap.data();
  // A banned account is already bounced to BannedScreen by the client-side
  // gate, but that gate is a UI convenience - this is the enforcement.
  //
  // An ABSENT accountStatus counts as active, deliberately. Accounts created
  // before Build Order step 9 introduced the field have no value at all, and
  // treating "missing" as "not active" locked those legacy accounts out of
  // matchmaking entirely - found live, with two real pre-step-9 test accounts
  // (PlayerOne/PlayerTwo) refused at the queue while a newer account sailed
  // through. This is the same trap firestore.rules already documents for
  // direct field access on legacy documents, and the same posture the app's
  // own gate takes (lib/app.dart checks `== 'banned'`, not `!= 'active'`):
  // only an explicit non-active value blocks.
  const accountStatus = user.accountStatus ?? "active";
  if (accountStatus !== "active") {
    throw new HttpsError("permission-denied", "This account can't join matches.");
  }

  // The ranked unlock gate is GONE - Ranked is available immediately. The
  // tutorial already does its job (a real practice round with live turn
  // machinery, mandatory before a first match), and under the monetization
  // model a free player's only battling is ranked during Sixes and Sevens,
  // so a gate demanding practice matches first would lock them out of the
  // one thing they get. See CLAUDE.md's Modes section.
  //
  // What replaces it is the entitlement check: who may battle, in which
  // mode, right now. Enforced here rather than only in the UI - the
  // client's button state is a convenience, this is the actual gate.
  const [monetization, windowConfig] = await Promise.all([
    readMonetizationConfig(),
    // Best-effort, same as resolveEventWindow: an unreadable window config
    // must never stop someone queueing, so it degrades to "no window",
    // which the entitlement check treats as no ranked-only hour.
    getFirestore().collection("config").doc("eventWindow").get()
        .then((snap) => readEventWindowConfig(snap.data()))
        .catch(() => ({enabled: false})),
  ]);
  const entitlement = battleEntitlement({
    user, mode, nowMs: Date.now(), windowConfig, config: monetization,
  });
  if (!entitlement.allowed) {
    throw new HttpsError("failed-precondition", entitlement.message, {
      reason: entitlement.reason,
      state: entitlement.state,
    });
  }

  // recentOpponentIds is documented in CLAUDE.md's user schema as "[array
  // with timestamps]"; tolerate both a plain array of ids and a map of
  // id -> timestamp, since nothing writes it yet (see completeMatch, which
  // starts populating the map form).
  const recent = user.recentOpponentIds ?? {};

  await queueRef(mode).child(auth.uid).set({
    uid: auth.uid,
    username: user.username ?? "Roaster",
    rating: user.rating ?? STARTING_RATING,
    tierIndex: tierIndexFor(user),
    blockedUserIds: user.blockedUserIds ?? [],
    recentOpponentIds: recent,
    joinedAt: Date.now(),
    // An active judge's effective head start, resolved HERE from the
    // user document rather than read during pairing: the pairing
    // transaction sees only the queue node, and reading a user doc per
    // candidate would turn one transaction into a fan-out over the
    // whole queue. Fixed for the life of this queue entry, which is
    // also fairer - judging while already waiting cannot jump you past
    // people who were queued before you.
    judgePriorityMs: judgePriorityFor(user),
    status: "waiting",
    // Whether this player can be woken by a push, which decides whether a
    // long wait may become a STANDING challenge. A standing challenge
    // works by notifying its owner when someone takes it up, so without a
    // registered device it would sit in the pool being paired against and
    // never answered - costing every player who matched it a five-minute
    // wait for nothing. See functions/standingChallenge.js.
    canNotify: Array.isArray(user.fcmTokens) && user.fcmTokens.length > 0,
  });

  // Reported so the waiting screen can confirm the reward landed. A perk
  // nobody is told about changes no behaviour, which is the whole reason
  // to surface it at all.
  return {queued: true, mode, judgePriorityMs: judgePriorityFor(user)};
}

/** Leaves the queue. Safe to call when not queued (idempotent) - the
 * client calls this on cancel, on dispose, and after collecting a match,
 * so it must never throw for an already-absent entry. */
async function leaveQueue(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const mode = data?.mode;
  assertMode(mode);
  await queueRef(mode).child(auth.uid).remove();
  return {left: true};
}

function lastPlayedAgainst(entry, opponentId) {
  const recent = entry.recentOpponentIds;
  if (!recent) return null;
  if (Array.isArray(recent)) return recent.includes(opponentId) ? Infinity : null;
  const ts = recent[opponentId];
  return typeof ts === "number" ? ts : null;
}

function isOnCooldown(a, b, now) {
  const t1 = lastPlayedAgainst(a, b.uid);
  const t2 = lastPlayedAgainst(b, a.uid);
  const mostRecent = Math.max(t1 ?? -Infinity, t2 ?? -Infinity);
  if (mostRecent === -Infinity) return false;
  if (mostRecent === Infinity) return true; // legacy array form: no timestamp, assume recent
  return now - mostRecent < REPEAT_OPPONENT_COOLDOWN_MS;
}

/**
 * The pairing DECISION, kept pure and separate from the transaction that
 * applies it so it can be exercised directly - see
 * test/matchmaking.test.js, which runs it over thousands of randomised
 * queues. That split is deliberate: this repo has already had one
 * matchmaking-adjacent bug (tournament byes) that a local simulation
 * caught before it reached a device, and the rules below - two-way
 * blocking, cooldown-as-preference, time-widening tiers - have exactly
 * the shape where an edge case hides.
 *
 * Mutates `queue` only by deleting stale entries. Returns the chosen
 * opponent, or null when nobody is currently compatible.
 */
function selectOpponent(queue, uid, now) {
  const me = queue[uid];
  // A standing entry can still be paired FROM as well as against - the
  // player may have reopened the app and started polling again, and there
  // is no reason to make them requeue to be matched.
  if (!me || (me.status !== "waiting" && me.status !== "standing")) return null;

  // A search that finds nobody becomes a STANDING challenge rather than
  // failing: it outlives the app being closed, so someone queueing hours
  // later matches it instantly and this player gets pushed. That is the
  // whole point - without it, queueing outside a busy hour returns nothing
  // and the core loop never fires.
  // Applied to EVERY entry, not just the caller's. Whether a wait has
  // become a standing challenge is a fact about how long it has waited,
  // not about who happens to be polling - and only transitioning the
  // caller would strand anyone who queued and closed the app before the
  // threshold, leaving them to be pruned as stale rather than left as the
  // standing challenge they had earned.
  // Note the stored status often stays "waiting" for a while: an
  // unsuccessful poll aborts its transaction, so this mutation is
  // discarded along with the stale-entry deletions above. That is
  // harmless, because standing-ness is DERIVED from age on every pass -
  // the entry is treated as standing by both the candidate filter and the
  // prune rule regardless of what is currently persisted, and the status
  // is written for real the next time a pairing commits. Confirmed live:
  // an entry left behind by a closed app still reads "waiting" in the
  // database while behaving as a standing challenge.
  for (const entry of Object.values(queue)) {
    if (shouldBecomeStanding(entry, now)) entry.status = "standing";
  }

  // Prune entries nobody is behind any more, so a crashed client's
  // leftover cannot be paired against. Two different rules, because the
  // two states mean different things: "waiting" claims someone is in front
  // of the app right now, while "standing" says the opposite and must
  // survive far longer. See functions/standingChallenge.js.
  for (const [id, entry] of Object.entries(queue)) {
    if (!isLive(entry, now, {staleMs: STALE_ENTRY_MS})) delete queue[id];
  }
  // Note: when this call ends up returning null, the transaction aborts
  // and these deletions are discarded along with it. That's intentional -
  // committing on every unsuccessful poll would rewrite the whole queue
  // node constantly. Stale entries are excluded from candidacy on every
  // pass regardless, so leaving them physically present is harmless; they
  // get cleaned up by the next successful pairing, by leaveQueue, or by
  // being overwritten when that user queues again.
  if (!queue[uid]) return null; // our own entry was the stale one

  const band = Math.floor((now - me.joinedAt) / TIER_WIDEN_INTERVAL_MS);
  const myBlocked = me.blockedUserIds ?? [];

  const candidates = Object.values(queue).filter((o) =>
    o.uid !== uid &&
    // Standing challenges are pairable exactly like live waits. This is
    // the change that makes off-peak work at all: without it, queueing at
    // 2pm and queueing at 8pm never meet.
    (o.status === "waiting" || o.status === "standing") &&
    Math.abs((o.tierIndex ?? 0) - (me.tierIndex ?? 0)) <= band &&
    // Blocking is checked in BOTH directions - CLAUDE.md's blocking
    // decision is a personal preference tool, and it would be useless
    // if the blocked party could still be served the blocker.
    !myBlocked.includes(o.uid) &&
    !(o.blockedUserIds ?? []).includes(uid),
  );
  if (candidates.length === 0) return null;

  // Cooldown is a PREFERENCE, not a filter: prefer someone we haven't
  // just played, but fall back to a repeat rather than leaving both
  // players stuck when they're the only two in the queue.
  const fresh = candidates.filter((o) => !isOnCooldown(me, o, now));
  const pool = fresh.length > 0 ? fresh : candidates;

  // Closest rating first; ties broken by who has waited longest, so
  // nobody starves while equally-good pairings keep appearing.
  // Someone live and waiting beats a standing challenge, always. A live
  // opponent can battle in the next thirty seconds; a standing one has to
  // be woken by a push and may not answer for minutes, or at all. Pairing
  // against a sleeper while a live player sits in the same queue would
  // make the app feel slower precisely when it is busiest.
  //
  // An active judge gets a bounded head start on the LAST of those
  // terms only. Deliberately not on the tier match: widening decides
  // how skill-appropriate a pairing is allowed to be, and rewarding
  // judging with worse-matched opponents would be a punishment dressed
  // as a perk. Nobody is ever excluded, only re-ordered - so this can
  // never starve a non-judge, and when the pool is thick enough for
  // instant pairing it changes nothing at all.
  pool.sort((a, b) =>
    (a.status === "standing" ? 1 : 0) - (b.status === "standing" ? 1 : 0) ||
    Math.abs(a.rating - me.rating) - Math.abs(b.rating - me.rating) ||
    effectiveWaitFrom(a) - effectiveWaitFrom(b),
  );
  return pool[0];
}

/**
 * A queue entry's effective join time, earlier for an active judge.
 *
 * Expressed as wait time so it rides the tiebreak that already exists
 * rather than adding a new axis to matchmaking. A malformed or absent
 * bonus is simply no bonus.
 */
function effectiveWaitFrom(entry) {
  const bonus = Number(entry?.judgePriorityMs);
  const clean = Number.isFinite(bonus) && bonus > 0 ?
    Math.min(bonus, MAX_PRIORITY_MS) : 0;
  return (entry?.joinedAt ?? 0) - clean;
}

/** The caller's judging head start, from their user document. */
function judgePriorityFor(user) {
  const {priorityBonusMs} = require("./judgeRewards");
  return priorityBonusMs(user, utcDayKey(Date.now()));
}

/**
 * Applies a pairing to the queue. Split out alongside selectOpponent so
 * the test suite can drive the exact same mutation the transaction does.
 */
function applyPairing(queue, uid, opponentId, matchId, channelName) {
  // Remembered before the status is overwritten: a match born from a
  // standing challenge has to be treated differently downstream, because
  // one of its players may be asleep. It gets a five-minute acceptance
  // window instead of the bio reveal's short timer, and if nobody answers
  // it is released rather than left pending.
  // Recorded on the entries themselves rather than returned alongside,
  // because the transaction can only commit the queue - and the statuses
  // are about to be overwritten with "matched", losing the distinction.
  const iWasStanding = queue[uid]?.status === "standing";
  const theyWereStanding = queue[opponentId]?.status === "standing";

  queue[uid] = {
    ...queue[uid], status: "matched", matchId, channelName, opponentId,
    wasStanding: iWasStanding,
  };
  queue[opponentId] = {
    ...queue[opponentId],
    status: "matched",
    matchId,
    channelName,
    opponentId: uid,
    wasStanding: theyWereStanding,
  };
  return queue;
}

/**
 * The pairing attempt. Runs as a single RTDB transaction over the whole
 * per-mode queue node so that two clients polling at the same instant
 * can't both claim the same opponent: the loser of the race re-runs
 * against the updated queue, sees its own entry already flipped to
 * "matched", and aborts without pairing again.
 *
 * Transacting on the parent node (rather than per-entry) is what makes
 * the two-sided claim atomic - two separate single-entry transactions
 * could interleave into A-claims-B while C-claims-A. The cost is that
 * every attempt reads and rewrites the whole queue for that mode, which
 * is fine at private-beta volume and is the documented scaling limit
 * here; sharding by tier band is the natural fix if it ever matters.
 */
async function attemptPairing(uid, mode, matchId, channelName, now) {
  const result = await queueRef(mode).transaction((queue) => {
    if (!queue) return queue;
    const opponent = selectOpponent(queue, uid, now);
    if (!opponent) return; // abort: not queued, already paired, or nobody compatible
    return applyPairing(queue, uid, opponent.uid, matchId, channelName);
  });

  if (!result.committed) return null;
  const queue = result.snapshot.val();
  const mine = queue?.[uid];
  // Only report a pairing if THIS attempt is the one that created it -
  // a commit that merely pruned stale entries also counts as committed.
  if (!mine || mine.status !== "matched" || mine.matchId !== matchId) return null;
  // Carried out so the prime-time-window determination can use the EARLIER
  // of the two players' queue times - see resolveEventWindow.
  return {
    ...mine,
    opponentJoinedAt: queue?.[mine.opponentId]?.joinedAt ?? null,
    opponentWasStanding: queue?.[mine.opponentId]?.wasStanding === true,
    // Carried out so the match can record BOTH ratings as they stood at
    // pairing. This transaction is the only place both are visible at
    // once, and by finalization time either player may have deleted
    // their account - see the missing-user branch in finalizeMatch.
    opponentRating: queue?.[mine.opponentId]?.rating ?? null,
  };
}

/**
 * Tells a player they've been paired, via push.
 *
 * This exists because of how pairing is discovered: the client finds its
 * match by polling, and those timers stall once the app is backgrounded.
 * Whoever's poll made the pairing is demonstrably in the foreground and
 * already knows - it's the OTHER player who may have queued and switched
 * away, and without this they'd sit in a stalled queue entry indefinitely.
 * Their entry stays flagged "matched" server-side until collected, so
 * returning to the app at any point still lands them in the right match.
 *
 * Entirely best-effort: a failed send must never fail the pairing itself,
 * which has already been committed by the time this runs.
 */
async function notifyMatchFound(opponentId, matchId, fromUsername) {
  try {
    const db = getFirestore();
    const snap = await db.collection("users").doc(opponentId).get();
    const tokens = snap.data()?.fcmTokens ?? [];
    if (tokens.length === 0) return;
    // Honour the per-category mute toggle. Match-found is the most useful
    // notification in the app, but forcing it on someone who switched it
    // off is how an app earns a system-level block - which silences every
    // other category too.
    if (!wantsCategory(snap.data(), "match_found")) return;

    const response = await getMessaging().sendEachForMulticast({
      tokens,
      notification: {
        title: "Opponent found",
        body: `${fromUsername || "Someone"} is ready to battle. Tap to start.`,
      },
      // The category is in the payload so that per-category mute settings
      // (CLAUDE.md decides on those, they aren't built) can be honoured
      // here later without changing the client's message handling.
      data: {category: "match_found", matchId},
      android: {priority: "high"},
    });

    // FCM reports permanently-dead tokens (app uninstalled, token rotated
    // on another device). Left in place they accumulate forever and every
    // future send wastes work on them, so prune as we learn about them.
    const dead = [];
    response.responses.forEach((r, i) => {
      const code = r.error?.code;
      if (code === "messaging/registration-token-not-registered" ||
          code === "messaging/invalid-registration-token") {
        dead.push(tokens[i]);
      }
    });
    if (dead.length > 0) {
      await db.collection("users").doc(opponentId)
          .update({fcmTokens: FieldValue.arrayRemove(...dead)});
    }
  } catch (e) {
    console.error(`match-found push to ${opponentId} failed:`, e.message);
  }
}

/**
 * Called on an interval by a waiting client. Returns either the match it
 * has been paired into (whether this call made the pairing or the
 * opponent's poll did) or a "still searching" status carrying enough
 * information for the UI to explain what's happening.
 */
async function pollMatchmaking(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const mode = data?.mode;
  assertMode(mode);
  const uid = auth.uid;
  const db = getFirestore();

  const snap = await queueRef(mode).child(uid).get();
  const entry = snap.val();
  if (!entry) return {status: "not_queued"};

  // The opponent's poll may have already paired us. Settings come from the
  // match document rather than being re-resolved, so this side runs exactly
  // what was stamped when the pairing was made - re-reading config here
  // could hand the two players different numbers if it changed in between.
  if (entry.status === "matched") {
    const matchSnap = await db.collection("matches").doc(entry.matchId).get();
    const m = matchSnap.data();
    return {
      status: "matched",
      matchId: entry.matchId,
      channelName: entry.channelName,
      opponentId: entry.opponentId,
      mode,
      settings: m?.settings ?? null,
      agoraUid: agoraUidFor(m, uid),
    };
  }

  const now = Date.now();
  // Reserve the id before the transaction so both entries can carry it,
  // then only write the Firestore document if the pairing actually
  // committed. .doc() allocates an id client-side without a round trip.
  const matchRef = db.collection("matches").doc();
  const channelName = `match_${matchRef.id}`;

  const paired = await attemptPairing(uid, mode, matchRef.id, channelName, now);
  if (!paired) {
    return {
      status: "searching",
      waitedMs: now - entry.joinedAt,
      tierBand: Math.floor((now - entry.joinedAt) / TIER_WIDEN_INTERVAL_MS),
    };
  }

  // Resolved once, here, and stamped onto the match document - so both
  // players run identical timings for this match regardless of when
  // either device last read config. See functions/matchSettings.js.
  const settings = await getMatchSettings(mode);

  // Whether this counts as a prime-time-window match, decided ONCE here and
  // stamped on the document.
  //
  // Judged at the START of the match, never the end: a battle that kicks
  // off at 6:58 and runs past 7:00 qualifies in full. Judging on completion
  // would penalise a long match and, far worse, give players a reason to
  // rush or bail out to beat the clock - the exact opposite of what an hour
  // designed to get people battling should encourage.
  //
  // Stamped rather than recomputed later for the same reason match settings
  // and vote confidence are: the hours are hand-editable in the console, and
  // a match must be judged by the rules in force when it was played, not by
  // whatever the config says afterwards. It also means the answer survives
  // the window being renamed, retimed, or switched off entirely.
  const eventWindow = await resolveEventWindow(now, earliestQueuedAt(paired));

  try {
    await matchRef.set({
      player1Id: uid,
      player2Id: paired.opponentId,
      // Both ratings as they stood at pairing.
      //
      // Recorded because a player can DELETE THEIR ACCOUNT before the
      // voting window closes, and CCPA deletion deliberately keeps the
      // match document while removing the user. Without this stamp the
      // departed player's rating becomes unknowable, and the survivor
      // is silently denied the rating change from a match they really
      // played - which is exactly the history the match document is
      // kept in order to protect.
      player1Rating: paired.rating ?? STARTING_RATING,
      player2Rating: paired.opponentRating ?? STARTING_RATING,
      mode,
      settings,
      eventWindow,
      // Where this pairing came from. A match born of a standing challenge
      // may have a player who is asleep, so it gets a five-minute
      // acceptance window instead of the bio reveal timer, and is released
      // rather than left pending if nobody answers.
      origin: paired.opponentWasStanding || paired.wasStanding ? "standing" : "live",
      challengerId: paired.opponentWasStanding ? paired.opponentId :
        paired.wasStanding ? uid : null,
      // Created at PAIRING time now, not at verdict time - the document is
      // what the two clients agree on (channel name, who the opponent is),
      // so it has to exist before the match rather than after it. Anything
      // downstream that only wants finished matches filters on this status:
      // see finalizeMatch, castVote, and the website feed.
      status: "pending",
      channelName,
      createdAt: FieldValue.serverTimestamp(),
      completedAt: null,
      voteFinalized: false,
      winnerId: null,
      voteCount: 0,
    });
  } catch (e) {
    // Both players are flagged "matched" against a match document that
    // doesn't exist - put them back in the queue rather than stranding
    // them on a channel with no match behind it.
    await Promise.all([
      queueRef(mode).child(uid).update({status: "waiting", matchId: null, channelName: null, opponentId: null}),
      queueRef(mode).child(paired.opponentId).update({status: "waiting", matchId: null, channelName: null, opponentId: null}),
    ]).catch(() => {});
    // Logged with the stack, because this catch swallowed a plain
    // ReferenceError in the object literal above and the only visible
    // symptom was matchmaking quietly never pairing anyone.
    console.error(`match creation failed for ${matchRef.id}:`, e);
    throw new HttpsError("internal", `Could not create the match: ${e.message}`);
  }

  // Awaited so the function doesn't return (and the instance potentially
  // freeze) mid-send, but it can never fail the call - see notifyMatchFound.
  await notifyMatchFound(paired.opponentId, matchRef.id, entry.username);

  return {
    status: "matched",
    matchId: matchRef.id,
    channelName,
    opponentId: paired.opponentId,
    mode,
    settings,
    // This caller created the match, so it is player1 by construction.
    agoraUid: PLAYER1_AGORA_UID,
  };
}

/**
 * Starts recording a match, called once by the host device as the match
 * actually begins (host election requires both players to be in the
 * channel, so this is the first moment there's anything worth recording).
 *
 * Recording only ever covers ranked and tournament matches, per
 * CLAUDE.md's recording scope decision - exhibition matches return
 * `skipped` rather than an error, since not recording them is correct
 * behaviour rather than a failure.
 *
 * Never throws for a recording problem. Two people are about to play a
 * match; losing the footage is bad, but blocking the match on a recording
 * vendor being unreachable is much worse.
 */
async function startMatchRecording(auth, data, creds) {
  const {matchRef, match} = await loadPendingMatch(auth, data?.matchId);
  const matchId = data.matchId;

  if (!RECORDED_MODES.includes(match.mode)) {
    return {started: false, reason: "mode-not-recorded"};
  }
  if (match.recording?.status === "recording") {
    // The other device raced us, or this is a retry. Not an error.
    return {started: false, reason: "already-recording"};
  }
  const {startRecording, isRecordingConfigured} = require("./cloudRecording");
  if (!isRecordingConfigured(creds)) {
    // Expected while the Agora RESTful credentials are still being set
    // up. Recorded on the document so it's visible that a match went
    // unrecorded for this reason rather than a failure.
    await writeRecordingState(matchId, {status: "unconfigured"});
    return {started: false, reason: "not-configured"};
  }

  const result = await startRecording(matchId, match.channelName, creds);
  if (!result.ok) {
    await writeRecordingState(matchId, {status: "start_failed", error: result.error});
    return {started: false, reason: "start-failed"};
  }

  await matchRef.set({
    recording: {
      status: "recording",
      resourceId: result.resourceId,
      sid: result.sid,
      startedAt: result.startedAt,
      // The human gate CLAUDE.md requires before anything is posted
      // publicly - covering both "is this fit for a public audience" and
      // the separate question of whether it would trip TikTok/Instagram/
      // YouTube's own rules, which are stricter than this app's internal
      // speech policy. Nothing in this pipeline publishes on its own.
      reviewStatus: "pending",
      published: false,
    },
  }, {merge: true});

  return {started: true};
}

/**
 * Finds a match the caller was paired into but never actually collected.
 *
 * This closes a real hole opened by the match-found push. A player can be
 * paired while the app is backgrounded, tap the notification (or just
 * reopen the app later) and — if the process had been killed in between —
 * land on Home with no route back: their queue entry is flagged "matched",
 * the match document is sitting there "pending", and nothing in the UI was
 * looking for either. Matched entries are deliberately never touched by
 * the stale-entry pruning, which is what makes them recoverable here.
 *
 * Checks every mode because the caller's own client no longer knows which
 * queue it was in after a cold start. Also self-heals: if the match has
 * since ended (the opponent skipped, or the sweep abandoned it), the dead
 * queue entry is cleared instead of being handed back.
 */
async function getActiveMatch(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();

  for (const mode of MODES) {
    const entry = (await queueRef(mode).child(auth.uid).get()).val();
    if (!entry || entry.status !== "matched" || !entry.matchId) continue;

    const snap = await db.collection("matches").doc(entry.matchId).get();
    if (!snap.exists || snap.data().status !== "pending") {
      await queueRef(mode).child(auth.uid).remove();
      continue;
    }

    return {
      found: true,
      matchId: entry.matchId,
      channelName: entry.channelName,
      opponentId: entry.opponentId,
      mode,
      settings: snap.data().settings ?? null,
      // Lets the client say WHY there is a match waiting. Someone who left
      // a standing challenge hours ago has forgotten they queued; "a match
      // is waiting" reads as a bug, while "someone took up your challenge"
      // reads as the thing they asked for.
      origin: snap.data().origin ?? "live",
      challengerId: snap.data().challengerId ?? null,
      agoraUid: agoraUidFor(snap.data(), auth.uid),
    };
  }

  return {found: false};
}

/**
 * Marks a paired match finished. Server-side so a client can't mark a
 * match it isn't in as complete (which would push it into the voting
 * pipeline and, for ranked, eventually into real rating changes).
 *
 * outcome "abandoned" is used when the match ended without a real
 * contest - currently the live content-violation auto-end (Build Order
 * step 9a). Those are finalized immediately with no winner so the hourly
 * rating sweep never reconsiders them, matching the previous behaviour
 * where a violation-ended match was simply never written at all.
 */
async function completeMatch(auth, data, creds = null) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {matchId, outcome = "completed", quality} = data || {};
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  if (!["completed", "abandoned"].includes(outcome)) {
    throw new HttpsError("invalid-argument", "outcome must be 'completed' or 'abandoned'.");
  }

  const db = getFirestore();
  const matchRef = db.collection("matches").doc(matchId);
  const matchSnap = await matchRef.get();
  if (!matchSnap.exists) throw new HttpsError("not-found", "Match not found.");
  const match = matchSnap.data();

  if (auth.uid !== match.player1Id && auth.uid !== match.player2Id) {
    throw new HttpsError("permission-denied", "Only a participant can complete this match.");
  }

  // The caller's own capture-quality summary, recorded BEFORE the settle
  // claim below and deliberately outside it. Both devices call this and
  // only one wins the claim - so writing the report inside would keep
  // whichever player raced faster and silently discard the other, who is
  // quite often the one who actually had the problem.
  //
  // Keyed by uid because each player reports on their OWN camera and mic;
  // there is no single number for a match. Never fatal: a bad report must
  // not stop a battle being settled.
  const cleanQuality = sanitiseQualityReport(quality);
  if (cleanQuality) {
    await matchRef.update({
      ["captureQuality." + auth.uid]: cleanQuality,
    }).catch((e) => console.error("quality report failed:", e.message));
  }

  // Claim the settle in a TRANSACTION, not a read-then-write. Both
  // clients call this when they reach the verdict, and a plain check
  // let both pass it before either wrote - so both went on to stop the
  // recording. One stop succeeded and one came back with Agora's "not
  // recording" error, and the loser's error overwrote the winner's file
  // list. Found on a real two-device match; the footage was fine but the
  // record of it wasn't.
  const claimed = await db.runTransaction(async (tx) => {
    const fresh = await tx.get(matchRef);
    if (fresh.data().status !== "pending") return false;
    tx.update(matchRef, {
      status: outcome,
      completedAt: FieldValue.serverTimestamp(),
      ...(outcome === "abandoned" ? {voteFinalized: true} : {}),
    });
    return true;
  });

  if (!claimed) {
    const current = (await matchRef.get()).data();
    return {status: current.status, alreadySettled: true};
  }

  // Stop the recording if one is running. Deliberately after the status
  // write, so a slow or failing Agora call can't leave the match stuck
  // "pending" - the match being settled matters more than the footage.
  // Agora's own maxIdleTime also stops the recording once both players
  // leave, so a failure here costs the file list, not the recording.
  const handle = match.recording;
  if (creds && handle?.resourceId && handle?.sid && handle.status === "recording") {
    const result = await stopRecording(matchId, match.channelName, handle, creds);
    await writeRecordingState(matchId, result.ok ?
      {status: "recorded", files: result.files, stoppedAt: Date.now()} :
      {status: "stop_failed", error: result.error});
  }

  if (outcome === "completed") {
    // Feeds the repeat-opponent cooldown on the next queue entry, and -
    // for exhibition matches - the counter that unlocks Ranked. Counted
    // on completion rather than on pairing so abandoning a match cannot
    // be used to speed-run the unlock.
    const now = Date.now();
    // A referral pays on ACTIVATION, and this is the moment it happens -
    // the referred player has now finished a real battle against a real
    // opponent, which is the bar that makes throwaway accounts not worth
    // farming. Best-effort: it must never fail the match that earned it.
    try {
      const {grantReferralIfEarned} = require("./referral");
      await Promise.all([match.player1Id, match.player2Id]
          .map((uid) => grantReferralIfEarned(uid)));
    } catch (e) {
      console.error(`referral check for ${matchId} failed:`, e.message);
    }

    // Daily quests, from the same completion event the referral uses.
    //
    // A FRIEND BATTLE DOES NOT COUNT, for the same reason it pays no
    // participation points: you choose your own opponent, so it would be
    // trivially arrangeable. The daily cap bounds the damage, but a quest
    // exists to pull people into the real loop - the shared queue and,
    // above all, judging - and clearing it against a friend by
    // appointment does none of that.
    if (match.mode !== "friend") try {
      const {recordQuestEvent} = require("./quests");
      await Promise.all([match.player1Id, match.player2Id]
          .map((uid) => recordQuestEvent(uid, "matches")));
    } catch (e) {
      console.error(`quest match event for ${matchId} failed:`, e.message);
    }

    const countsTowardUnlock = match.mode === "exhibition";
    await Promise.all([match.player1Id, match.player2Id].map((uid, i) => {
      const opponent = i === 0 ? match.player2Id : match.player1Id;
      return db.collection("users").doc(uid).update({
        [`recentOpponentIds.${opponent}`]: now,
        ...(countsTowardUnlock ?
          {exhibitionMatchesPlayed: FieldValue.increment(1)} : {}),
      }).catch(() => {});
    }));

    // Points for turning up, doubled inside the prime-time window - a
    // POINTS multiplier only, never rating, which would give high-rated
    // players a reason to sit out the very hour it exists to fill.
    //
    // Awarded on COMPLETION and keyed by match, so the two devices racing
    // to settle the same match cannot both pay out; awardPoints is
    // idempotent per source. Failures are swallowed: points are a reward,
    // never a precondition for finishing a battle.
    //
    // NOT PAID FOR A FRIEND BATTLE. finalizeMatch already withholds the
    // rating change and the win bonus there, for a reason that applies
    // just as much here: you CHOOSE your opponent, and no cooldown stops
    // you choosing the same one all evening, so paying per match is a
    // straight farm between two accounts. What a friend battle pays
    // instead is the clip and the crowd's verdict.
    //
    // This was missed when friend battles were built - the mode skipped
    // the rating and the win bonus but still collected the turn-up
    // award on every single match. The live check could not see it
    // because it wrote `status: completed` straight to Firestore rather
    // than calling this function.
    //
    // RANKED AND TOURNAMENT ONLY, as of the XP ladder (2026-08-25). Career
    // points ARE the XP that drives the visible title, and the decision is
    // that only ranked matches earn XP. Exhibition is casual and stakes-
    // free, so it now pays nothing at all (no XP, no clip currency) rather
    // than paying the participation award it used to; friend was already
    // excluded, for the farm reason above. Tournament stays in because it
    // is genuinely competitive, staked play.
    if (match.mode === "ranked" || match.mode === "tournament") try {
      const {awardPoints, pointsSettings, awardAmount} = require("./points");
      const rates = await pointsSettings();
      const multiplier = match.eventWindow?.qualified === true ?
        rates.eventWindowMultiplier : 1;
      await Promise.all([match.player1Id, match.player2Id].map((uid) =>
        awardPoints(uid, {
          reason: "match_played",
          sourceId: matchId,
          amount: awardAmount(rates.matchPlayed, {multiplier}),
        })));
    } catch (e) {
      console.error(`match points for ${matchId} failed:`, e.message);
    }
  }

  return {status: outcome};
}

/**
 * CLAUDE.md's skip/decline decision allows "2-3 skips per day" - enough of
 * an escape hatch for a genuinely bad pairing, few enough that nobody can
 * cherry-pick easy opponents all evening.
 */
const MAX_SKIPS_PER_DAY = 3;

/** Re-declared here so the pairing comparator can clamp a queue entry's
 * stored bonus without requiring judgeRewards on every sort comparison. */
const {MAX_PRIORITY_MS} = require("./judgeRewards");

/** UTC calendar day, used to reset the daily skip allowance. Deliberately
 * UTC rather than the player's local midnight: it needs to agree between
 * the server and every device, and a per-user timezone isn't stored. The
 * practical effect is that the allowance resets at 5pm Pacific rather than
 * local midnight - fine for V1, worth revisiting if players notice. */
function utcDayKey(nowMs) {
  return new Date(nowMs).toISOString().slice(0, 10);
}

async function loadPendingMatch(auth, matchId) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  const matchRef = getFirestore().collection("matches").doc(matchId);
  const snap = await matchRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "Match not found.");
  const match = snap.data();
  if (auth.uid !== match.player1Id && auth.uid !== match.player2Id) {
    throw new HttpsError("permission-denied", "Not a participant in this match.");
  }
  return {matchRef, match};
}

/**
 * Marks the caller ready during the pre-match bio reveal. Both clients
 * watch the match document, so this is how each learns the other is done
 * reading - the bio reveal ends as soon as both are ready, or when its
 * timer runs out, per CLAUDE.md ("up to 1 minute OR until both players tap
 * ready, whichever comes first").
 *
 * Server-side rather than a direct client write because clients can't
 * write the matches collection at all (firestore.rules), and because
 * readiness has to be attributable - a client shouldn't be able to mark
 * its opponent ready.
 */
async function setMatchReady(auth, data) {
  const {matchRef, match} = await loadPendingMatch(auth, data?.matchId);
  if (match.status !== "pending") {
    return {status: match.status, ready: match.readyPlayerIds ?? []};
  }
  const update = {[`lastSeenAt.${auth.uid}`]: Date.now()};
  // Doubles as a heartbeat so the bio reveal can tell "still reading" from
  // "walked away". Readiness alone cannot do that: with a long reveal
  // someone may legitimately sit there for minutes without tapping ready,
  // and ejecting them would silently collapse the window back to seconds.
  if (data?.ready !== false) {
    update.readyPlayerIds = FieldValue.arrayUnion(auth.uid);
  }
  await matchRef.update(update);
  const after = (await matchRef.get()).data();
  return {
    status: "pending",
    ready: after.readyPlayerIds ?? [],
    lastSeenAt: after.lastSeenAt ?? {},
  };
}

/** How long without a heartbeat before an opponent counts as gone.
 * Comfortably more than the client's heartbeat interval, so one dropped
 * call or a slow network never ejects someone who is still there. */
const PRESENCE_STALE_MS = 75 * 1000;

/**
 * Whether the caller is stuck waiting on an opponent who has left.
 *
 * THIS IS WHAT MAKES A LONG BIO REVEAL SAFE. The reveal ends as soon as
 * both players tap Ready, so its maximum only ever matters when one of
 * them does not - which means the real cost of a 10-minute window is ten
 * minutes of being held hostage by somebody who walked away, ending in a
 * no-contest. Bounding that by PRESENCE rather than by the clock lets the
 * window be as long as the developer wants without that cost.
 *
 * Judged on heartbeats, deliberately, NOT on readiness: a player thinking
 * hard about their material for five minutes is using the feature exactly
 * as intended and must never be thrown out for it.
 *
 * Pure, so the rule is testable without Firestore or a clock.
 */
function opponentUnresponsive({match, uid, nowMs, staleMs = PRESENCE_STALE_MS}) {
  if (!match || match.status !== "pending") return false;
  const opponentId = match.player1Id === uid ? match.player2Id :
    match.player2Id === uid ? match.player1Id : null;
  if (!opponentId) return false;
  // Never bail on someone who has already committed - at that point the
  // match is about to start regardless.
  if ((match.readyPlayerIds ?? []).includes(opponentId)) return false;
  const seen = Number(match.lastSeenAt?.[opponentId]);
  // No heartbeat at all yet is not evidence of absence until enough time
  // has passed since PAIRING for one to have arrived. createdAt is a
  // Firestore Timestamp, so it has to be converted - reading it as a
  // number would give NaN, fall through to 0, and silently disable the
  // fallback entirely, meaning a player who never sent a single heartbeat
  // could never be released. Exactly the class of bug that only shows up
  // for the case the feature exists to handle.
  const reference = Number.isFinite(seen) && seen > 0 ?
    seen : toMillis(match.createdAt) ?? 0;
  if (reference <= 0) return false;
  return nowMs - reference > staleMs;
}

/**
 * Leaves a match whose opponent has gone, WITHOUT spending a skip.
 *
 * A skip is for declining someone you were offered; this is for someone
 * who never turned up, and charging the daily allowance for their absence
 * would punish the wrong person. Nobody is forfeited either - failing to
 * arrive at a bio reveal is not the broken promise that an accepted-then-
 * abandoned challenge is.
 */
async function releaseUnresponsiveMatch(auth, data) {
  const {matchRef, match} = await loadPendingMatch(auth, data?.matchId);
  if (match.status !== "pending") {
    return {released: false, reason: "already-settled"};
  }
  if (!opponentUnresponsive({match, uid: auth.uid, nowMs: Date.now()})) {
    throw new HttpsError("failed-precondition",
        "Your opponent is still there.");
  }
  await matchRef.update({
    status: "abandoned",
    voteFinalized: true,
    abandonedReason: "opponent-unresponsive",
    completedAt: FieldValue.serverTimestamp(),
  });
  return {released: true};
}

/**
 * Declines a proposed match after seeing the opponent's bio (CLAUDE.md's
 * skip/decline decision). Spends one of the caller's daily skips, settles
 * the match as abandoned so it never reaches voting or rating, and lets
 * the other player find out via their own listener on the document.
 *
 * The counter lives server-side and is protected in firestore.rules for
 * the same reason rating is: a client that could reset its own
 * skipsUsedToday would have unlimited skips, which defeats the entire
 * point of the limit (cherry-picking easy opponents).
 */
async function skipMatch(auth, data) {
  const {matchRef, match} = await loadPendingMatch(auth, data?.matchId);
  if (match.status !== "pending") {
    throw new HttpsError("failed-precondition", "This match can no longer be skipped.");
  }

  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);
  const now = Date.now();
  const today = utcDayKey(now);

  // Transaction so two rapid skips can't both read the same count and
  // each write count+1, spending only one of the allowance.
  const remaining = await db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const user = snap.data() ?? {};
    const sameDay = user.skipsResetDate === today;
    const used = sameDay ? (user.skipsUsedToday ?? 0) : 0;
    // Base plus whatever today's judging earned, under one hard
    // ceiling. The ceiling is the point: skips are worth MORE to a
    // rating-manipulator than to an honest player, so an uncapped mint
    // would reintroduce the opponent cherry-picking the cap prevents.
    const {skipAllowance} = require("./judgeRewards");
    const allowed = skipAllowance(user, today, MAX_SKIPS_PER_DAY);
    if (used >= allowed) {
      throw new HttpsError(
          "resource-exhausted",
          `You've used all ${allowed} of today's skips.`,
      );
    }
    tx.update(userRef, {skipsUsedToday: used + 1, skipsResetDate: today});
    return allowed - (used + 1);
  });

  await matchRef.update({
    status: "abandoned",
    // Settled immediately so the hourly rating sweep never reconsiders it,
    // and so neither player takes a result from a match nobody played.
    voteFinalized: true,
    completedAt: FieldValue.serverTimestamp(),
    skippedByUserId: auth.uid,
  });

  return {skipped: true, skipsRemaining: remaining};
}

/** Read-only: how many skips the caller has left today, so the UI can show
 * it before they spend one (and hide the button at zero). */
async function getSkipAllowance(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const snap = await getFirestore().collection("users").doc(auth.uid).get();
  const user = snap.data() ?? {};
  const today = utcDayKey(Date.now());
  const used = user.skipsResetDate === today ? (user.skipsUsedToday ?? 0) : 0;
  // Must agree with the transaction above, or the UI offers a skip the
  // server then refuses - or hides one the player has actually earned.
  const {skipAllowance, earnedSkips} = require("./judgeRewards");
  const max = skipAllowance(user, today, MAX_SKIPS_PER_DAY);
  return {
    remaining: Math.max(0, max - used),
    max,
    // Broken out so the client can say WHERE the extra came from. An
    // allowance that silently grows is a reward nobody knows they got.
    earned: earnedSkips(user, today),
  };
}

module.exports = {
  enterQueue,
  leaveQueue,
  pollMatchmaking,
  completeMatch,
  startMatchRecording,
  getActiveMatch,
  RECORDED_MODES,
  // Every queue that exists, so the online-count publisher (presence.js)
  // sweeps exactly the same set of modes matchmaking uses rather than
  // keeping its own list that could silently drift out of step.
  MODES,
  setMatchReady,
  releaseUnresponsiveMatch,
  opponentUnresponsive,
  PRESENCE_STALE_MS,
  skipMatch,
  getSkipAllowance,
  utcDayKey,
  MAX_SKIPS_PER_DAY,
  // Exported so judging rewards expire on exactly the same boundary
  // the skip allowance resets on - see judgeRewards.js.
  utcDayKey,
  tierIndexFor,
  // Exported for test/matchmaking.test.js - the pairing rules are the part
  // worth exercising directly, independently of RTDB.
  selectOpponent,
  applyPairing,
  isOnCooldown,
  TIER_WIDEN_INTERVAL_MS,
  REPEAT_OPPONENT_COOLDOWN_MS,
  STALE_ENTRY_MS,
  earliestQueuedAt,
};
