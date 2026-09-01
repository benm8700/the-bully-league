import type { Metadata } from "next";
import { Fraunces, Inter } from "next/font/google";
import "./globals.css";
import { AuthProvider } from "@/lib/AuthProvider";
import { SiteHeader } from "@/components/SiteHeader";
import { SiteFooter } from "@/components/SiteFooter";
import { AgeGate } from "@/components/AgeGate";

// The same pairing the app now bundles ("Comedy Night" base theme), so a
// visitor arriving from a shared clip does not land on something that looks
// like a different product. Fraunces is the display face: an elegant
// high-contrast serif, loaded as a VARIABLE font with its optical-size axis
// so headlines read premium/editorial at large sizes without going stiff.
// Body stays Inter.
const fraunces = Fraunces({
  variable: "--font-display",
  subsets: ["latin"],
  axes: ["opsz"],
});

const inter = Inter({
  variable: "--font-body",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "The Bully League",
  description:
    "Get randomly matched 1-on-1 with a stranger for a live, timed roast battle. The crowd votes the winner. Climb the ranks. 18+.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${fraunces.variable} ${inter.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">
        <AuthProvider>
          <AgeGate />
          <SiteHeader />
          {children}
          <SiteFooter />
        </AuthProvider>
      </body>
    </html>
  );
}
