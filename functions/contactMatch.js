/**
 * Phone numbers kept PRIVATE, and "friends from your contacts" (2026-11-19).
 *
 * WHY THIS EXISTS. Phone numbers used to live on users/{uid}, which every
 * signed-in member can read (profiles are public inside the app) - so a
 * modified client could harvest every member's number. They now live in two
 * server-only places that firestore.rules closes to every client:
 *
 *   userPrivate/{uid}      {phoneNumber, phoneVerifiedAt}
 *   phoneIndex/{hash}      {uid}     hash = sha256 hex of the E.164 number
 *
 * CONTACT MATCHING. The app hashes each number in the player's address book
 * ON THE PHONE (same normalisation + sha256 as phoneHash below) and sends
 * only the hashes. The server answers which hashes belong to members who can
 * be found, and NEVER stores what it was sent: no contact list, no hashes,
 * nothing logged. Names and emails never leave the phone.
 *
 * Safeguards: a member can switch off being found ("contactDiscoverable":
 * false on their user doc); blocks hide both ways; banned/deleted accounts
 * never match; the caller never matches themselves; and a per-account daily
 * limit stops anyone using this to test numbers in bulk (a 10-digit number
 * space is small enough to enumerate, which is exactly why hashes alone are
 * not treated as secret and the lookup is rate-limited).
 */
const crypto = require("crypto");
const {HttpsError} = require("firebase-functions/v2/https");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");

const MAX_HASHES_PER_CALL = 500;
const MAX_HASHES_PER_DAY = 3000;
const MAX_CALLS_PER_DAY = 20;
const HASH_RE = /^[0-9a-f]{64}$/;

/** sha256 hex of an E.164 number - MUST match lib/core/contact_hash.dart. */
function phoneHash(e164) {
  return crypto.createHash("sha256").update(String(e164)).digest("hex");
}

/** Records a member's verified number privately and indexes it. */
async function indexPhone(db, uid, e164) {
  const batch = db.batch();
  batch.set(db.collection("userPrivate").doc(uid), {
    phoneNumber: e164,
    phoneVerifiedAt: FieldValue.serverTimestamp(),
  }, {merge: true});
  batch.set(db.collection("phoneIndex").doc(phoneHash(e164)), {uid});
  // Any copy left on the public profile goes.
  batch.set(db.collection("users").doc(uid), {
    phoneNumber: FieldValue.delete(),
    phoneVerifiedAt: FieldValue.delete(),
  }, {merge: true});
  await batch.commit();
}

/** The uid whose verified number this is, or null. */
async function uidForPhone(db, e164) {
  if (!e164) return null;
  const snap = await db.collection("phoneIndex").doc(phoneHash(e164)).get();
  if (snap.exists && snap.data()?.uid) return snap.data().uid;
  // Accounts not yet migrated.
  const legacy = await db.collection("users")
      .where("phoneNumber", "==", e164).limit(1).get();
  return legacy.empty ? null : legacy.docs[0].id;
}

/** A member's verified number (server use only), or null. */
async function phoneForUid(db, uid, userData) {
  const priv = await db.collection("userPrivate").doc(uid).get();
  return priv.data()?.phoneNumber ?? userData?.phoneNumber ?? null;
}

/** Removes a deleted account's private number and its index entry. */
async function forgetPhone(db, uid) {
  const priv = await db.collection("userPrivate").doc(uid).get();
  const phone = priv.data()?.phoneNumber;
  if (phone) {
    const idx = db.collection("phoneIndex").doc(phoneHash(phone));
    const cur = await idx.get();
    if (cur.exists && cur.data()?.uid === uid) await idx.delete();
  }
  if (priv.exists) await priv.ref.delete();
}

/** Pure: cleans the incoming hash list (dedupe, shape, cap). */
function cleanHashes(raw) {
  if (!Array.isArray(raw)) return [];
  const out = new Set();
  for (const h of raw) {
    if (typeof h === "string" && HASH_RE.test(h)) out.add(h);
    if (out.size >= MAX_HASHES_PER_CALL) break;
  }
  return [...out];
}

/** Pure: may this account look up `count` more hashes today? */
function rateCheck(state, count, dayKey) {
  const s = state && state.day === dayKey ? state : {day: dayKey, calls: 0, hashes: 0};
  if (s.calls + 1 > MAX_CALLS_PER_DAY || s.hashes + count > MAX_HASHES_PER_DAY) {
    return {ok: false, next: s};
  }
  return {ok: true, next: {day: dayKey, calls: s.calls + 1, hashes: s.hashes + count}};
}

/** Pure: should this member show up for this caller? */
function visibleMatch(callerUid, caller, uid, user) {
  if (!user || uid === callerUid) return false;
  if (user.contactDiscoverable === false) return false;
  if (user.accountStatus && user.accountStatus !== "active") return false;
  if ((user.blockedUserIds ?? []).includes(callerUid)) return false;
  if ((caller?.blockedUserIds ?? []).includes(uid)) return false;
  return true;
}

async function matchContacts(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const hashes = cleanHashes(data?.hashes);
  if (hashes.length === 0) return {matches: []};

  const db = getFirestore();
  const uid = auth.uid;
  const dayKey = new Date().toISOString().slice(0, 10);
  const limitRef = db.collection("contactMatchLimits").doc(uid);
  const allowed = await db.runTransaction(async (tx) => {
    const cur = await tx.get(limitRef);
    const r = rateCheck(cur.data(), hashes.length, dayKey);
    if (r.ok) tx.set(limitRef, r.next);
    return r.ok;
  });
  if (!allowed) {
    throw new HttpsError("resource-exhausted",
        "That's a lot of lookups for one day. Try again tomorrow.");
  }

  const idxSnaps = await db.getAll(
      ...hashes.map((h) => db.collection("phoneIndex").doc(h)));
  const hits = idxSnaps.filter((s) => s.exists && s.data()?.uid)
      .map((s) => ({hash: s.id, uid: s.data().uid}));
  if (hits.length === 0) return {matches: []};

  const caller = (await db.collection("users").doc(uid).get()).data() ?? {};
  const userSnaps = await db.getAll(
      ...hits.map((h) => db.collection("users").doc(h.uid)));
  const matches = [];
  hits.forEach((h, i) => {
    const u = userSnaps[i].exists ? userSnaps[i].data() : null;
    if (!visibleMatch(uid, caller, h.uid, u)) return;
    matches.push({
      hash: h.hash,
      uid: h.uid,
      username: u.username ?? null,
      photoUrl: u.profile?.facePhotoUrl ?? u.profile?.photoUrls?.[0] ?? null,
    });
  });
  return {matches};
}

/**
 * One-off migration: moves every users/{uid}.phoneNumber into userPrivate +
 * phoneIndex and strips it from the public doc. Idempotent.
 */
async function migratePhones(db = getFirestore()) {
  const snap = await db.collection("users").where("phoneNumber", ">", "").get();
  let moved = 0;
  for (const d of snap.docs) {
    const phone = d.data().phoneNumber;
    if (typeof phone !== "string" || !phone.startsWith("+")) continue;
    await indexPhone(db, d.id, phone);
    moved++;
  }
  return {moved};
}

module.exports = {
  phoneHash, indexPhone, uidForPhone, phoneForUid, forgetPhone,
  cleanHashes, rateCheck, visibleMatch, matchContacts, migratePhones,
  MAX_HASHES_PER_CALL, MAX_HASHES_PER_DAY, MAX_CALLS_PER_DAY,
};
