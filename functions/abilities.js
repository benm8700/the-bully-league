const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {isSubscriber, isInTrial, readMonetizationConfig} = require("./entitlement");
const {computeTitleFromXp} = require("./rating");

/**
 * Match ABILITIES (power-ups) for the regular/qualifier mode - a paid, fun edge
 * layer that drives subscriptions and the points economy. Developer's design
 * (2026-10-11):
 *   - ONLY in regular/qualifier play, NEVER in the Main Stage finals (those stay
 *     pure skill).
 *   - Every ability only DISRUPTS or DEFENDS (throws the opponent off / protects
 *     you) - never adds score - and both players can buy the same things, so it
 *     stays fair-enough while being a real monetization surface.
 *   - Hybrid acquisition: subscribers get a small FREE allowance per match;
 *     anyone can BUY more with points. Committed PRE-match (a loadout on the
 *     ready-up screen); tapped to deploy in-match.
 *
 * THIS LAYER IS THE ECONOMY ONLY and is FORMAT-INDEPENDENT. The catalog's
 * economy (cost / free allowance / cap / enabled) is live config
 * (config/abilities, bounds-checked, PLACEHOLDER numbers for the advisor
 * review). Each ability's in-match EFFECT is applied client/match-side and is
 * format-specific (see the round-times note) - add it there, not here.
 *
 * Points are spent exactly like the day pass / clip grant / emoji scrub:
 * pointsBalance (spendable, never the career total) + an idempotent ledger
 * entry. The per-match loadout is server-only and each player sees only THEIR
 * own (the opponent's is a surprise).
 *
 * REMOVAL / KILL SWITCH (the whole feature is built to be trivially undoable if
 * the developer decides abilities are a bad idea):
 *   - INSTANT OFF, no deploy, no code change: set config/abilities.enabled =
 *     false (its current state). Every path reads it - getLoadout and
 *     getMatchAbilities return enabled:false with zero counts, purchaseAbility
 *     refuses, and the client hides the loadout + deploy UI. The chess-clock
 *     engine is then seeded with 0 interrupts/instant/extend/go-first, so a
 *     regular match simply runs as a PLAIN chess clock (talk budget + free
 *     yield + shot-clock). That is the complete "abilities removed" runtime
 *     behaviour, reached by flipping one boolean. Verified by
 *     functions/live/abilityChecks.js.
 *   - FULL CODE REMOVAL (tidiness only; the flag above already does the job):
 *     delete this file, its 3 callables in index.js (getLoadout /
 *     purchaseAbility / getMatchAbilities), test/abilities.test.js,
 *     live/abilityChecks.js, and the client abilities_service.dart /
 *     ability_deploy_bar.dart / loadout_panel.dart; then strip the ability
 *     wiring from match_screen.dart (the getMatchAbilities seed in _seedBattle,
 *     the Interrupt/Instant controls, the deploy bar, _onDeployAbility, the
 *     tomato splat). DO NOT delete mainStageBattle.js / main_stage_battle.dart:
 *     the chess-clock engine is SHARED with the Main Stage finals and IS the
 *     match format - with abilities gone it just runs with zero seeds.
 */

// The catalog. `deploy` says WHERE the ability is used, so the client knows
// which surface shows it: "controls" = the chess-clock Interrupt button;
// "bar" = the mid-match tap-to-deploy bar (tomato/extend); "prematch" = decided
// at battle start from the loadout (go-first), never tapped mid-match. Adding a
// new entry here (plus a DEFAULTS row) wires it through the whole economy -
// resolveAbilityConfig / boughtOf / getLoadout all iterate the catalog.
const ABILITY_CATALOG = {
  interrupt: {
    id: "interrupt",
    name: "Interrupt",
    description:
      "Cut into your opponent while they hold the floor and steal it.",
    deploy: "controls",
  },
  instantInterrupt: {
    id: "instantInterrupt",
    name: "Instant Interrupt",
    description:
      "Cut in with NO mercy - steal the floor the instant you tap, no grace.",
    deploy: "controls",
  },
  tomato: {
    id: "tomato",
    name: "Tomato",
    description: "Splat a tomato across your opponent's screen to rattle them.",
    deploy: "bar",
  },
  fart: {
    id: "fart",
    name: "Fart",
    description:
      "Rip a random fart on your opponent's phone to throw them off. They " +
      "hear it; it never lands in the recording.",
    deploy: "bar",
  },
  extend: {
    id: "extend",
    name: "+5 Seconds",
    description:
      "Add 5 seconds to your clock - even to buy time against an interrupt.",
    deploy: "bar",
  },
  goFirst: {
    id: "goFirst",
    name: "Go First",
    description: "Take the floor first. If you both bring it, it's a coin flip.",
    deploy: "prematch",
  },
  goSecond: {
    id: "goSecond",
    name: "Go Second",
    description:
      "Let your opponent go first - you take the floor second. If you both " +
      "want the same slot, it's a coin flip.",
    deploy: "prematch",
  },
  skipWarmup: {
    id: "skipWarmup",
    name: "Skip Warm-Up",
    description:
      "End the warm-up for BOTH players the instant you tap - no waiting " +
      "for them to agree. Get straight to the battle.",
    deploy: "warmup",
  },
};

// Per-ability economy defaults, overridable per field from config/abilities.
// PLACEHOLDERS (advisor review): interrupt is the priciest (biggest edge);
// go-first is capped at one (you either lead or you don't).
//
// `unlockXp` is the RANK GATE (developer's 2026-10-15 design): each ability
// unlocks at a rank, cheaper/lower-impact ones first, so climbing the ladder
// hands you the toys one by one - a progression carrot that rewards playing.
// The thresholds are the XP_TIERS mins from rating.js: 50 Open Micer, 150
// Class Clown, 350 The Funny Friend, 700 Door Guy, 1200 Regular, 2000
// Headliner. In Challenge-a-Friend EVERYTHING is unlocked and free regardless
// (taste freely); the gate + cost only bite in ranked/qualifier play.
const DEFAULTS = {
  interrupt: {cost: 500, subFree: 1, maxPerMatch: 3, enabled: true, unlockXp: 1200},
  // Deliberately expensive and never free - the no-grace cut is the biggest
  // edge in the game, so it costs a TON of points and even subscribers buy it.
  instantInterrupt: {cost: 2000, subFree: 0, maxPerMatch: 1, enabled: true, unlockXp: 2000},
  tomato: {cost: 150, subFree: 2, maxPerMatch: 5, enabled: true, unlockXp: 50},
  // A cheap, early, purely-for-fun rattle like the tomato. Ephemeral (plays
  // locally on the target, never recorded).
  fart: {cost: 150, subFree: 2, maxPerMatch: 5, enabled: true, unlockXp: 50},
  extend: {cost: 250, subFree: 1, maxPerMatch: 3, enabled: true, unlockXp: 150},
  goFirst: {cost: 300, subFree: 1, maxPerMatch: 1, enabled: true, unlockXp: 350},
  // Go Second unlocks AFTER Go First (developer's call): same price/cap, a
  // higher rank. You either lead or you don't, so it's one per match.
  goSecond: {cost: 300, subFree: 1, maxPerMatch: 1, enabled: true, unlockXp: 700},
  // Expensive and never free - one person ends the warm-up for both, so it's a
  // real "I'm ready, let's go" power rather than a freebie.
  skipWarmup: {cost: 1500, subFree: 0, maxPerMatch: 1, enabled: true, unlockXp: 700},
};
const ABILITY_FALLBACK =
  {cost: 500, subFree: 0, maxPerMatch: 3, enabled: true, unlockXp: 0};

function clampInt(v, min, max, fallback) {
  const n = Math.floor(Number(v));
  return Number.isFinite(n) && n >= min && n <= max ? n : fallback;
}

/** Merge config/abilities over DEFAULTS, bounds-checked per field. Pure. */
function resolveAbilityConfig(doc) {
  const d = doc || {};
  const out = {enabled: d.enabled !== false};
  for (const id of Object.keys(ABILITY_CATALOG)) {
    const base = DEFAULTS[id] || ABILITY_FALLBACK;
    const cfg = (d[id] && typeof d[id] === "object") ? d[id] : {};
    out[id] = {
      cost: clampInt(cfg.cost, 0, 100000, base.cost),
      subFree: clampInt(cfg.subFree, 0, 10, base.subFree),
      maxPerMatch: clampInt(cfg.maxPerMatch, 0, 20, base.maxPerMatch),
      unlockXp: clampInt(cfg.unlockXp, 0, 100000, base.unlockXp),
      enabled: cfg.enabled !== undefined ? cfg.enabled !== false : base.enabled,
    };
  }
  return out;
}

async function abilityConfig(db = getFirestore()) {
  const snap = await db.collection("config").doc("abilities").get();
  return resolveAbilityConfig(snap.data());
}

/** Spendable balance - a legacy account with no balance field inherits its
 * career total (reading a missing balance as zero would confiscate everything
 * earned before spending existed). Matches dayPass/clipGrants/emojiScrub. */
function spendableBalance(user) {
  const raw = Number(user && user.pointsBalance);
  return Number.isFinite(raw) ?
    Math.max(0, raw) : Math.max(0, Number((user && user.points) || 0));
}

/** Career XP (the lifetime `points` total that drives the rank title) - the
 * signal the unlock gate reads. A missing/garbage value is 0. */
function careerXp(user) {
  const n = Number(user && user.points);
  return Number.isFinite(n) ? Math.max(0, n) : 0;
}

/** Whether this ability is UNLOCKED for the player - gated on reaching the
 * ability's unlockXp rank, in EVERY mode. Friend battles make unlocked
 * abilities FREE (see freeAllowance) but do NOT unlock locked ones: the
 * progression chase has to mean something (developer's call 2026-10-16,
 * reversing the earlier friend-mode auto-unlock). PURE. */
function isUnlocked(user, abilityCfg) {
  return careerXp(user) >= (abilityCfg.unlockXp || 0);
}

/** The FREE per-match allowance for an ability. In a friend battle EVERYTHING
 * is free and fully stocked (the per-match cap). Otherwise it's the
 * subscriber/trial perk. The UNLOCK gate is applied at the call sites, not
 * here, so this stays a pure "how many are free" question. */
function freeAllowance(user, nowMs, abilityCfg, trialDays, friendMode) {
  if (friendMode) return abilityCfg.maxPerMatch;
  const entitled = isSubscriber(user, nowMs) || isInTrial(user, nowMs, trialDays);
  return entitled ? abilityCfg.subFree : 0;
}

/**
 * PURE. Whether one more of an ability can be bought, and the cost. Clamped by
 * the per-match cap (free + bought) and the balance.
 */
function purchasePlan({free, bought, maxPerMatch, cost, balance}) {
  const total = Math.max(0, free) + Math.max(0, bought);
  if (total >= maxPerMatch) return {ok: false, reason: "max"};
  if (balance < cost) return {ok: false, reason: "insufficient"};
  return {ok: true, cost, newBought: Math.max(0, bought) + 1};
}

/** The caller's bought counts for a match (0s if none). */
function boughtOf(loadoutDoc) {
  const b = loadoutDoc && loadoutDoc.bought;
  const out = {};
  for (const id of Object.keys(ABILITY_CATALOG)) {
    out[id] = Math.max(0, Math.floor(Number(b && b[id]) || 0));
  }
  return out;
}

async function requireParticipant(db, matchId, uid) {
  const snap = await db.collection("matches").doc(matchId).get();
  if (!snap.exists) throw new HttpsError("not-found", "Match not found.");
  const m = snap.data();
  if (m.player1Id !== uid && m.player2Id !== uid) {
    throw new HttpsError("permission-denied", "You're not in this match.");
  }
  // Abilities are a regular/qualifier thing - never the Main Stage finals.
  if (m.mainStage) {
    throw new HttpsError("failed-precondition",
        "Abilities aren't allowed in the finals.");
  }
  if (m.status === "completed" || m.status === "abandoned") {
    throw new HttpsError("failed-precondition", "This match is over.");
  }
  return m;
}

/** What the client needs to render the pre-match loadout. */
async function getLoadout(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const matchId = data && data.matchId;
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  const db = getFirestore();
  const match = await requireParticipant(db, matchId, auth.uid);
  const friendMode = match.mode === "friend";
  const nowMs = Date.now();
  const [cfg, mon, userSnap, loadoutSnap] = await Promise.all([
    abilityConfig(db),
    readMonetizationConfig(db),
    db.collection("users").doc(auth.uid).get(),
    db.collection("matchLoadouts").doc(matchId)
        .collection("players").doc(auth.uid).get(),
  ]);
  const user = userSnap.data() || {};
  const balance = spendableBalance(user);
  const bought = boughtOf(loadoutSnap.data());
  // Locked abilities are still SHOWN (grayed, with "Unlock at <rank>") rather
  // than hidden - they're the progression carrot, so a player should see what
  // they're climbing toward.
  const abilities = Object.values(ABILITY_CATALOG)
      .filter((a) => cfg.enabled && cfg[a.id].enabled)
      .map((a) => {
        const c = cfg[a.id];
        const unlocked = isUnlocked(user, c);
        const free = unlocked ? freeAllowance(user, nowMs, c, mon.trialDays, friendMode) : 0;
        const b = bought[a.id];
        return {
          id: a.id, name: a.name, description: a.description, deploy: a.deploy,
          cost: c.cost, free, bought: b, total: free + b, max: c.maxPerMatch,
          unlocked,
          unlockXp: c.unlockXp,
          unlockTitle: computeTitleFromXp(c.unlockXp),
          // Nothing to buy when it's free (friend mode) or locked.
          canBuy: unlocked && !friendMode &&
            free + b < c.maxPerMatch && balance >= c.cost,
        };
      });
  return {enabled: cfg.enabled, balance, matchId, friendFree: friendMode, abilities};
}

/**
 * Buy ONE of an ability for a match (adds to the per-match loadout, spends
 * points for anything beyond the free allowance). Idempotent on `requestId`.
 */
async function purchaseAbility(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {matchId, abilityId, requestId} = data || {};
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  if (!ABILITY_CATALOG[abilityId]) {
    throw new HttpsError("invalid-argument", "Unknown ability.");
  }
  const db = getFirestore();
  const match = await requireParticipant(db, matchId, auth.uid);
  const friendMode = match.mode === "friend";
  const [cfg, mon] = await Promise.all([abilityConfig(db), readMonetizationConfig(db)]);
  if (!cfg.enabled || !cfg[abilityId].enabled) {
    throw new HttpsError("failed-precondition", "That ability isn't available.");
  }
  const c = cfg[abilityId];
  const nowMs = Date.now();

  // Friend battles hand out everything free and fully stocked, so there is
  // nothing to buy - the client won't offer it, but short-circuit cleanly if
  // it's called anyway rather than charging or refusing.
  if (friendMode) {
    return {ok: true, friendFree: true, abilityId, bought: 0};
  }

  const rid = (typeof requestId === "string" && requestId.length > 0 &&
      requestId.length <= 128) ?
    requestId :
    `auto_${Date.now()}_${Math.random().toString(36).slice(2)}`;

  const userRef = db.collection("users").doc(auth.uid);
  const loadoutRef = db.collection("matchLoadouts").doc(matchId)
      .collection("players").doc(auth.uid);
  const entryRef = userRef.collection("pointsLedger")
      .doc(`ability_${matchId}_${rid}`);

  const result = await db.runTransaction(async (tx) => {
    const [entrySnap, userSnap, loadoutSnap] = await Promise.all([
      tx.get(entryRef), tx.get(userRef), tx.get(loadoutRef),
    ]);
    const user = userSnap.data() || {};
    const bought = boughtOf(loadoutSnap.data());
    if (entrySnap.exists) {
      return {ok: true, duplicate: true, abilityId,
        bought: bought[abilityId], balance: spendableBalance(user)};
    }
    // Rank gate: can't buy an ability you haven't unlocked yet (ranked only;
    // friend mode already returned above).
    if (!isUnlocked(user, c)) {
      return {ok: false, reason: "locked", balance: spendableBalance(user)};
    }
    const free = freeAllowance(user, nowMs, c, mon.trialDays, friendMode);
    const balance = spendableBalance(user);
    const plan = purchasePlan({
      free, bought: bought[abilityId], maxPerMatch: c.maxPerMatch,
      cost: c.cost, balance,
    });
    if (!plan.ok) return {ok: false, reason: plan.reason, balance, cost: c.cost};

    tx.set(entryRef, {
      reason: "ability", sourceId: rid, abilityId, matchId,
      amount: -plan.cost, createdAt: FieldValue.serverTimestamp(),
    });
    tx.set(userRef, {pointsBalance: balance - plan.cost}, {merge: true});
    tx.set(loadoutRef, {
      bought: {[abilityId]: plan.newBought},
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    return {ok: true, abilityId, bought: plan.newBought, cost: plan.cost,
      balance: balance - plan.cost};
  });

  if (!result.ok) {
    const messages = {
      max: "You've brought the max of this one.",
      insufficient: `That costs ${c.cost} points - you don't have enough.`,
      locked: `Reach ${computeTitleFromXp(c.unlockXp)} to unlock this.`,
    };
    throw new HttpsError("failed-precondition",
        messages[result.reason] || "Couldn't buy that.", {reason: result.reason});
  }
  return result;
}

/**
 * Resolve BOTH players' ability counts for a match, server-authoritatively.
 * The chess-clock battle is host-driven peer-to-peer, and the host needs each
 * player's real interrupt/extend/go-first counts to seed the engine - but a
 * player's loadout is server-only (matchLoadouts is closed to client reads), so
 * the host cannot read the opponent's. This callable does it with the Admin
 * SDK: a participant asks, and gets the resolved {free+bought} per ability for
 * both sides. It is the honest-path source of truth for seeding (a modified
 * host can cheat its own engine regardless - the same limit as all the P2P turn
 * state; this at least means the counts come from real purchases).
 */
async function getMatchAbilities(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const matchId = data && data.matchId;
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  const db = getFirestore();
  const m = await requireParticipant(db, matchId, auth.uid);
  const friendMode = m.mode === "friend";
  const nowMs = Date.now();
  const [cfg, mon] = await Promise.all([abilityConfig(db), readMonetizationConfig(db)]);
  const uids = [m.player1Id, m.player2Id];
  const [users, loadouts] = await Promise.all([
    Promise.all(uids.map((u) => db.collection("users").doc(u).get())),
    Promise.all(uids.map((u) => db.collection("matchLoadouts").doc(matchId)
        .collection("players").doc(u).get())),
  ]);
  const players = {};
  uids.forEach((uid, i) => {
    const user = users[i].data() || {};
    const bought = boughtOf(loadouts[i].data());
    const counts = {};
    for (const id of Object.keys(ABILITY_CATALOG)) {
      // Off, or not yet unlocked for THIS player's rank -> they bring none.
      if (!cfg.enabled || !cfg[id].enabled ||
          !isUnlocked(user, cfg[id])) {
        counts[id] = 0;
        continue;
      }
      const free = freeAllowance(user, nowMs, cfg[id], mon.trialDays, friendMode);
      counts[id] = Math.min(free + bought[id], cfg[id].maxPerMatch);
    }
    players[uid] = counts;
  });
  return {enabled: cfg.enabled, players};
}

module.exports = {
  getLoadout,
  purchaseAbility,
  getMatchAbilities,
  resolveAbilityConfig,
  purchasePlan,
  freeAllowance,
  isUnlocked,
  careerXp,
  boughtOf,
  ABILITY_CATALOG,
  DEFAULTS,
};
