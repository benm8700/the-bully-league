export const runtime = "nodejs";

const DAY_MS = 24 * 60 * 60 * 1000;
const STATUSES = ["active", "banned", "flagged"];
const REVIEW_STATES = ["reviewed", "actioned", "dismissed"];
const CONFIG_DOCS = ["tournament", "monetization"];

// All admin WRITES go through here, each verified admin-only and stamped with
// who did it. Admin SDK writes bypass firestore.rules, which is exactly why the
// verifyAdmin gate (real ID token + isAdmin) is non-negotiable.
//
// firebase-admin is imported DYNAMICALLY inside the handler (see
// metrics/route.ts): a top-level import crashes the serverless function on
// Vercel with a bare 500.
export async function POST(request: Request) {
  let FieldValue: typeof import("firebase-admin/firestore").FieldValue;
  let db: FirebaseFirestore.Firestore;
  let admin: { uid: string };
  try {
    const { AdminAuthError, getAdminFirestore, verifyAdmin } = await import(
      "@/lib/firebaseAdmin"
    );
    ({ FieldValue } = await import("firebase-admin/firestore"));
    try {
      admin = await verifyAdmin(request);
    } catch (e) {
      if (e instanceof AdminAuthError) {
        return Response.json({ error: e.message }, { status: e.status });
      }
      throw e;
    }
    db = getAdminFirestore();
  } catch (e) {
    return Response.json(
      { error: String((e as Error)?.message ?? e) },
      { status: 500 },
    );
  }

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return Response.json({ error: "Invalid JSON" }, { status: 400 });
  }

  const type = String(body.type ?? "");
  const stamp = {
    by: admin.uid,
    at: FieldValue.serverTimestamp(),
  };
  const bad = (msg: string) => Response.json({ error: msg }, { status: 400 });

  try {
    switch (type) {
      case "setAccountStatus": {
        const uid = String(body.uid ?? "");
        const status = String(body.status ?? "");
        if (!uid) return bad("uid required");
        if (!STATUSES.includes(status)) return bad("invalid status");
        await db.collection("users").doc(uid).set(
          {
            accountStatus: status,
            moderation: {
              reason: String(body.reason ?? ""),
              ...stamp,
            },
          },
          { merge: true },
        );
        return Response.json({ ok: true, uid, status });
      }

      case "compAccess": {
        const uid = String(body.uid ?? "");
        if (!uid) return bad("uid required");
        const days = Number(body.days ?? 0);
        const subscription: Record<string, unknown> = {
          active: true,
          source: "comp",
          grantedBy: admin.uid,
          grantedAtMs: Date.now(),
        };
        // days <= 0 => open-ended (no expiry), matching entitlement.js's
        // "no expiry recorded means open-ended" rule for hand-granted access.
        if (Number.isFinite(days) && days > 0) {
          subscription.expiresAtMs = Date.now() + days * DAY_MS;
        }
        await db.collection("users").doc(uid).set({ subscription }, { merge: true });
        return Response.json({ ok: true, uid, days: days > 0 ? days : "open" });
      }

      case "revokeAccess": {
        const uid = String(body.uid ?? "");
        if (!uid) return bad("uid required");
        await db
          .collection("users")
          .doc(uid)
          .set({ subscription: { active: false } }, { merge: true });
        return Response.json({ ok: true, uid });
      }

      case "setConfigFlag": {
        const doc = String(body.doc ?? "");
        if (!CONFIG_DOCS.includes(doc)) return bad("invalid config doc");
        const enabled = body.enabled === true;
        await db
          .collection("config")
          .doc(doc)
          .set({ enabled, updatedBy: admin.uid }, { merge: true });
        return Response.json({ ok: true, doc, enabled });
      }

      case "markPrizeFulfilled": {
        const id = String(body.id ?? "");
        if (!id) return bad("id required");
        await db
          .collection("prizeFulfillments")
          .doc(id)
          .set({ status: "fulfilled", fulfilled: stamp }, { merge: true });
        return Response.json({ ok: true, id });
      }

      case "reviewReport":
      case "resolveSupport":
      case "resolveAppeal": {
        const collection =
          type === "reviewReport"
            ? "reports"
            : type === "resolveSupport"
              ? "supportRequests"
              : "banAppeals";
        const id = String(body.id ?? "");
        const status = String(body.status ?? "reviewed");
        if (!id) return bad("id required");
        if (!REVIEW_STATES.includes(status)) return bad("invalid status");
        await db
          .collection(collection)
          .doc(id)
          .set({ status, review: stamp }, { merge: true });
        return Response.json({ ok: true, id, status });
      }

      case "editorsChoice": {
        // Feature a battle in the Home spotlight (the founder's Editor's
        // Choice). Denormalises the display fields so the app reads one cheap
        // `featured` listener; grants both performers the permanent Editor's
        // Choice badge ONCE (the first time THIS match is featured - a
        // remove+re-add can re-credit, which is harmless since the counter is
        // invisible and the badge threshold is 1).
        const matchId = String(body.matchId ?? "");
        if (!matchId) return bad("matchId required");
        const matchSnap = await db.collection("matches").doc(matchId).get();
        if (!matchSnap.exists) return bad("no such match");
        const m = matchSnap.data() ?? {};
        const p1 = String(m.player1Id ?? "");
        const p2 = String(m.player2Id ?? "");
        if (!p1 || !p2) return bad("match has no players");
        const users = db.collection("users");
        const [u1, u2] = await Promise.all([users.doc(p1).get(), users.doc(p2).get()]);
        const nameOf = (s: FirebaseFirestore.DocumentSnapshot) =>
          String(s.data()?.username ?? "Unknown");
        const hl = (m.highlight ?? {}) as Record<string, unknown>;
        const pub = (hl.publicUrls ?? {}) as Record<string, string>;
        const clipUrl =
          hl.published === true ? (pub.vertical ?? pub.landscape ?? null) : null;
        const featuredRef = db.collection("featured").doc(matchId);
        await db.runTransaction(async (tx) => {
          const f = await tx.get(featuredRef);
          const firstTime = !f.exists;
          tx.set(
            featuredRef,
            {
              matchId,
              player1Id: p1,
              player2Id: p2,
              player1Name: nameOf(u1),
              player2Name: nameOf(u2),
              clipUrl: clipUrl ?? null,
              pickedBy: admin.uid,
              pickedAt: FieldValue.serverTimestamp(),
            },
            { merge: true },
          );
          if (firstTime) {
            if (u1.exists) {
              tx.update(users.doc(p1), {
                editorsChoicePicks: FieldValue.increment(1),
              });
            }
            if (u2.exists) {
              tx.update(users.doc(p2), {
                editorsChoicePicks: FieldValue.increment(1),
              });
            }
          }
        });
        return Response.json({ ok: true, matchId, clip: clipUrl != null });
      }

      case "removeEditorsChoice": {
        // Pull a battle from the spotlight. The performers KEEP the badge -
        // being picked happened, so it is earned-and-kept; only the counter is
        // left alone (never decremented).
        const matchId = String(body.matchId ?? "");
        if (!matchId) return bad("matchId required");
        await db.collection("featured").doc(matchId).delete();
        return Response.json({ ok: true, matchId });
      }

      default:
        return bad(`unknown action: ${type}`);
    }
  } catch (e) {
    console.error("admin action failed:", (e as Error).message);
    return Response.json({ error: "Action failed" }, { status: 500 });
  }
}
