import Link from "next/link";

export function SiteFooter() {
  return (
    <footer className="px-6 py-6 border-t border-foreground/10 text-center">
      <Link href="/legal" className="text-xs text-foreground/40 hover:text-foreground/70">
        Terms of Service & Privacy Policy
      </Link>
    </footer>
  );
}
