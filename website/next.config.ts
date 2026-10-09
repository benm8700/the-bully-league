import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // firebase-admin lazy-requires native/sub-packages (gRPC, google-gax) that
  // Next's bundler does NOT trace into a Route Handler's serverless function on
  // Vercel - so every /api/admin/* route crashed at import with a 500 in prod
  // while the Server Components using the same import (homepage, /matches)
  // worked. Marking it external keeps it a plain node_modules require that
  // Vercel's file tracer then includes wholesale. The documented fix.
  serverExternalPackages: ["firebase-admin"],
  // App stores specifically ask for a "Privacy Policy URL" and often a
  // Terms URL too, but CLAUDE.md's Security & Compliance Baseline decided
  // on ONE combined document rather than maintaining separate pages - these
  // just alias the conventional URLs to it.
  async redirects() {
    return [
      { source: "/privacy", destination: "/legal", permanent: false },
      { source: "/terms", destination: "/legal", permanent: false },
      // Browser voting is gone - it required sign-in, and accounts can
      // only be created in the app, so the visitor it was aimed at could
      // never use it. Any /vote/... link already shared lands on the feed
      // rather than a 404.
      { source: "/vote/:matchId", destination: "/matches", permanent: false },
    ];
  },
};

export default nextConfig;
