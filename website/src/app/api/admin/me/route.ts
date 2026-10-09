export const runtime = "nodejs";

import { getAdminAuth, getAdminFirestore } from "@/lib/firebaseAdmin";

// Tells the admin page whether the signed-in caller is an admin, so it can
// render the dashboard or a plain "not authorized". Returns 200 with
// admin:false for an anonymous or non-admin caller (not a 401) so the page can
// handle it gracefully; the real security gate is verifyAdmin on every
// data/action route, not this.
export async function GET(request: Request) {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) return Response.json({ signedIn: false, admin: false });
  try {
    const decoded = await getAdminAuth().verifyIdToken(match[1]!);
    const snap = await getAdminFirestore()
      .collection("users")
      .doc(decoded.uid)
      .get();
    return Response.json({
      signedIn: true,
      admin: snap.data()?.isAdmin === true,
      uid: decoded.uid,
      email: decoded.email ?? null,
    });
  } catch {
    return Response.json({ signedIn: false, admin: false });
  }
}
