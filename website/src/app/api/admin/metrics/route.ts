export const runtime = "nodejs";

import { AdminAuthError, verifyAdmin } from "@/lib/firebaseAdmin";
import { collectMetrics } from "@/lib/adminMetrics";

export async function GET(request: Request) {
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
}
