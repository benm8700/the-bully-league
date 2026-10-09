export const runtime = "nodejs";

// Tells the admin page whether the signed-in caller is an admin, so it can
// render the dashboard or a plain "not authorized". Returns 200 either way (the
// real security gate is verifyAdmin on every data/action route). firebase-admin
// is imported DYNAMICALLY so a serverless load failure is caught and reported
// in `_diag` rather than crashing the function with a bare 500.
export async function GET(request: Request) {
  try {
    const { describeCaller } = await import("@/lib/firebaseAdmin");
    return Response.json(await describeCaller(request));
  } catch (e) {
    return Response.json({
      signedIn: false,
      admin: false,
      _diag: String((e as Error)?.message ?? e),
    });
  }
}
