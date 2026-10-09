export const runtime = "nodejs";

import { AdminAuthError, getAdminFirestore, verifyAdmin } from "@/lib/firebaseAdmin";
import { Timestamp } from "firebase-admin/firestore";

function shape(id: string, d: FirebaseFirestore.DocumentData) {
  const sub = d.subscription ?? {};
  const created = d.createdAt;
  return {
    uid: id,
    username: d.username ?? null,
    rankTitle: d.rankTitle ?? null,
    rating: d.rating ?? null,
    points: d.points ?? null,
    pointsBalance: d.pointsBalance ?? null,
    wins: d.wins ?? null,
    losses: d.losses ?? null,
    accountStatus: d.accountStatus ?? "active",
    isAdmin: d.isAdmin === true,
    subscription: {
      active: sub.active === true,
      expiresAtMs: sub.expiresAtMs ?? null,
      source: sub.source ?? null,
    },
    createdAtMs: created instanceof Timestamp ? created.toMillis() : null,
  };
}

// Search users by username (case-insensitive prefix) or exact uid. Admin-only.
export async function GET(request: Request) {
  try {
    await verifyAdmin(request);
  } catch (e) {
    if (e instanceof AdminAuthError) {
      return Response.json({ error: e.message }, { status: e.status });
    }
    throw e;
  }

  const q = (new URL(request.url).searchParams.get("q") ?? "").trim();
  if (q.length < 2) return Response.json({ results: [] });

  const db = getAdminFirestore();
  const results: ReturnType<typeof shape>[] = [];
  const seen = new Set<string>();

  // Exact uid match first (so an admin can paste a uid).
  const byId = await db.collection("users").doc(q).get();
  if (byId.exists) {
    results.push(shape(byId.id, byId.data()!));
    seen.add(byId.id);
  }

  // Username prefix (usernameLower is the normalized field the app indexes).
  const lower = q.toLowerCase();
  const snap = await db
    .collection("users")
    .where("usernameLower", ">=", lower)
    .where("usernameLower", "<=", lower + "")
    .limit(25)
    .get();
  for (const doc of snap.docs) {
    if (seen.has(doc.id)) continue;
    results.push(shape(doc.id, doc.data()));
    seen.add(doc.id);
  }

  return Response.json({ results });
}
