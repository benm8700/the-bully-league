import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  /* config options here */
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
