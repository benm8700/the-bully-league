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
    ];
  },
};

export default nextConfig;
