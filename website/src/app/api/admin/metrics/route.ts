export const runtime = "nodejs";

// firebase-admin is imported DYNAMICALLY inside the handler. A top-level import
// of firebase-admin (directly or transitively) crashes the Route Handler's
// serverless function at load on Vercel with a bare 500 - proven in production:
// the identical me route only started working once its import was deferred this
// way. Deferring it also lets any real failure be caught and reported.
export async function GET(request: Request) {
  try {
    const { AdminAuthError, verifyAdmin } = await import("@/lib/firebaseAdmin");
    const { collectMetrics } = await import("@/lib/adminMetrics");
    try {
      await verifyAdmin(request);
    } catch (e) {
      if (e instanceof AdminAuthError) {
        return Response.json({ error: e.message }, { status: e.status });
      }
      throw e;
    }
    const metrics = await collectMetrics();
    return Response.json(metrics);
  } catch (e) {
    return Response.json(
      { error: String((e as Error)?.message ?? e) },
      { status: 500 },
    );
  }
}
