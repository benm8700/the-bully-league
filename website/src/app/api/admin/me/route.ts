export const runtime = "nodejs";

// Tells the admin page whether the signed-in caller is an admin, so it can
// render the dashboard or a plain "not authorized". Returns 200 with
// admin:false for an anonymous or non-admin caller (not a 401) so the page can
// handle it gracefully; the real security gate is verifyAdmin on every
// data/action route, not this.
//
// firebase-admin is imported DYNAMICALLY inside the handler (not top-level) so
// a module-load failure in Vercel's serverless runtime is caught and reported
// in the body rather than crashing the function with a bare 500 - the exact
// failure this route hit in production. With serverExternalPackages:
// ["firebase-admin"] (next.config.ts) the import should succeed; `_diag` is a
// cheap safety net that makes any remaining failure diagnosable in one request.
export async function GET(request: Request) {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) return Response.json({ signedIn: false, admin: false });
  try {
    const { getAdminAuth, getAdminFirestore } = await import(
      "@/lib/firebaseAdmin"
    );
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
  } catch (e) {
    return Response.json({
      signedIn: false,
      admin: false,
      _diag: String((e as Error)?.message ?? e),
    });
  }
}
