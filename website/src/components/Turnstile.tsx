"use client";

import Script from "next/script";
import { useEffect, useRef, useState } from "react";

// Same Turnstile site key as the Flutter app's turnstile_config.dart -
// site keys are public by design (only the secret key, used server-side
// in castVote, is sensitive). Uses Turnstile's explicit-render API
// (window.turnstile.render) instead of the data-attribute/global-callback
// approach the Flutter WebView version uses, since that's the more
// natural fit for a React component with its own ref/state.
const TURNSTILE_SITE_KEY = "0x4AAAAAAENmrVwMJIwWsReg";

declare global {
  interface Window {
    turnstile?: {
      render: (
        container: HTMLElement,
        options: { sitekey: string; theme: string; callback: (token: string) => void },
      ) => string;
      remove: (widgetId: string) => void;
    };
  }
}

export function Turnstile({ onVerify }: { onVerify: (token: string) => void }) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [scriptLoaded, setScriptLoaded] = useState(false);

  useEffect(() => {
    if (!scriptLoaded || !containerRef.current || !window.turnstile) return;
    const widgetId = window.turnstile.render(containerRef.current, {
      sitekey: TURNSTILE_SITE_KEY,
      theme: "dark",
      callback: onVerify,
    });
    return () => window.turnstile?.remove(widgetId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scriptLoaded]);

  return (
    <>
      <Script
        src="https://challenges.cloudflare.com/turnstile/v0/api.js"
        onLoad={() => setScriptLoaded(true)}
      />
      <div ref={containerRef} />
    </>
  );
}
