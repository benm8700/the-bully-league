import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Terms & Privacy — The Bully League",
};

function H2({ children }: { children: React.ReactNode }) {
  return <h2 className="text-xl font-bold mt-10 mb-3">{children}</h2>;
}

function H3({ children }: { children: React.ReactNode }) {
  return <h3 className="text-base font-semibold mt-6 mb-2">{children}</h3>;
}

function P({ children }: { children: React.ReactNode }) {
  return <p className="text-sm text-foreground/80 leading-relaxed mb-3">{children}</p>;
}

function Li({ children }: { children: React.ReactNode }) {
  return <li className="text-sm text-foreground/80 leading-relaxed mb-1">{children}</li>;
}

export default function LegalPage() {
  return (
    <main className="flex-1 px-6 py-16">
      <div className="max-w-2xl mx-auto">
        <h1 className="text-3xl font-bold mb-2">Terms of Service & Privacy Policy</h1>
        <p className="text-sm text-foreground/50 mb-1">Last updated: August 13, 2026</p>

        <div className="border border-yellow-600/40 bg-yellow-600/10 rounded-lg px-4 py-3 my-6 text-sm text-foreground/80">
          <strong>Placeholder notice:</strong> this document was drafted to accurately reflect
          The Bully League&apos;s actual product decisions and has not yet been reviewed by a
          lawyer. It is published now because Google Play and Apple both require a working
          privacy policy link before approving any app listing, including private beta testing.
          It should be reviewed by real legal counsel before any public launch.
        </div>

        <H2>Terms of Service</H2>

        <H3>1. Who can use The Bully League</H3>
        <P>
          You must be 18 or older to create an account. We check this using Google Play&apos;s
          Age Signals API at signup - if the signal indicates you&apos;re under 18, account
          creation is blocked entirely. We do not ask for or store your birthdate, only a
          pass/fail signal.
        </P>

        <H3>2. Account types</H3>
        <P>
          <strong>Spectator</strong> accounts can browse, watch, and vote on matches with a
          lightweight signup. <strong>Battler</strong> accounts unlock the ability to be matched
          for live roast battles, and require a full profile (photos, bio info) and a one-time
          manual review before you can play. You can upgrade from Spectator to Battler at any
          time.
        </P>

        <H3>3. Mature content and free speech</H3>
        <P>
          This is a comedy roast platform. Offensive language, slurs used in a comedic context,
          and no-holds-barred material are allowed by design - we do not moderate the content of
          live matches in real time, and you consent to being exposed to this kind of content by
          using the app. What is <em>not</em> allowed: deliberate hate or bigotry not in service
          of comedy, sustained targeted bullying or harassment beyond the roast format itself,
          and anything outside the format entirely (threats, doxxing, etc). Reports are reviewed
          by a human, case by case - we can suspend or ban an account for any reason, at our
          discretion, and you can appeal a ban through the in-app appeal form.
        </P>

        <H3>4. Recording and consent</H3>
        <P>
          Matches are recorded on video and audio. Before every match, both participants must
          give explicit consent to being recorded - this is a separate, distinct step, not
          buried in these terms. If your match is a ranked or tournament match, the recording may
          be selected as a highlight and posted publicly on our website or social media (see
          Section 5). Exhibition matches are not recorded or posted, except Friend Battles, which
          are recorded and eligible for community voting even though they don&apos;t affect your
          rating. Raw, unposted recordings are deleted after 7 days.
        </P>

        <H3>5. Rights to your match footage</H3>
        <P>
          By consenting to recording, you also grant The Bully League a license to use, edit,
          clip, and redistribute footage from your ranked and tournament matches - including
          posting highlight clips to our website, Instagram, TikTok, YouTube, or similar
          platforms. This license is separate from and in addition to your consent to being
          recorded in the first place.
        </P>

        <H3>6. Points, ranking, and prizes</H3>
        <P>
          Your rank and rating reflect competitive performance and cannot be purchased. Points
          are a separate currency, earned only (not currently purchasable), spent on cosmetic
          items that have no effect on gameplay or matchmaking. Tournaments are skill contests -
          winners are determined by community vote on comedic performance, not chance. As of this
          writing, tournament prizes are points only; no real-money prizes are active. If cash
          prizes are activated in the future, eligibility will be limited by your state or
          country&apos;s laws, and additional terms will apply.
        </P>

        <H3>7. Subscriptions</H3>
        <P>
          Optional premium subscriptions unlock features like unwatermarked clip downloads and a
          stats dashboard, billed through Apple&apos;s or Google&apos;s standard subscription
          systems. Ranked play, titles, and rating always stay free.
        </P>

        <H3>8. Termination</H3>
        <P>
          We may suspend or terminate your account at any time, for any reason, including
          violation of these terms. You may delete your account at any time from the app.
        </P>

        <H3>9. Disclaimers</H3>
        <P>
          The app is provided &quot;as is.&quot; We don&apos;t guarantee uninterrupted service,
          and we&apos;re not liable for the content other users say during a match - you use the
          app knowing it features unfiltered, potentially offensive comedic content.
        </P>

        <H2>Privacy Policy</H2>

        <H3>1. Information we collect</H3>
        <ul className="list-disc pl-5 mb-3">
          <Li>Phone number, email address, and password (handled entirely by Firebase Auth - we never see or store your raw password).</Li>
          <Li>An age-bracket signal from Google Play Age Signals (not your birthdate).</Li>
          <Li>Battler profile info: profession, education, hometown, and interests (required); relationship status, pets, and favorite food (optional); a free-text &quot;ammo&quot; field (optional); at least 5 profile photos, one of which must clearly show your face.</Li>
          <Li>Match recordings (video and audio), deleted after 7 days unless posted as a highlight.</Li>
          <Li>Device identifiers, logged to help detect multi-account abuse.</Li>
          <Li>Usage and crash data via Firebase Analytics and Crashlytics.</Li>
        </ul>

        <H3>2. Third-party services we use</H3>
        <P>
          Firebase (authentication, database, storage, push notifications, analytics) by Google;
          Agora for live video calls; Cloudflare Turnstile to verify votes aren&apos;t automated;
          Google Cloud Vision to automatically detect and block nudity or explicit content during
          matches and in profile photos. Each of these processes some of your data as part of
          providing the app&apos;s functionality.
        </P>

        <H3>3. How we use your information</H3>
        <P>
          To operate matchmaking, ranking, voting, and moderation; to verify your age and
          identity as needed; to detect abuse (fake accounts, vote manipulation, collusion); and
          to communicate with you (match alerts, vote reminders, support responses).
        </P>

        <H3>4. Your rights</H3>
        <P>
          If you&apos;re a California resident, you can request deletion of your account and
          personal data (CCPA). If you&apos;re in the UK, you have rights to access, correct, or
          erase your data (UK GDPR). You can request deletion from within the app. One exception:
          if a highlight clip from your match was already posted publicly before your deletion
          request, we&apos;ll delete your profile data and stop future use of your identity, but
          we won&apos;t retroactively unpublish content that was already live and consented-to at
          the time it was posted.
        </P>

        <H3>5. Children&apos;s privacy</H3>
        <P>
          The Bully League is not intended for anyone under 18, and we block account creation for
          any account signaling as underage. We do not knowingly collect data from minors.
        </P>

        <H3>6. Data security</H3>
        <P>
          Data is encrypted in transit and at rest via our infrastructure providers (Firebase,
          Google Cloud). No system is perfectly secure, and we can&apos;t guarantee absolute
          security of your information.
        </P>

        <H3>7. Changes to this policy</H3>
        <P>
          We may update this document as the app changes. Material changes will be reflected
          here with an updated &quot;Last updated&quot; date.
        </P>

        <H3>8. Contact</H3>
        <P>
          Questions about these terms or your data can be sent through the Support & Feedback
          option in the app.
        </P>
      </div>
    </main>
  );
}
