# Social Posting — Phase 2 Setup Checklist (BACKLOG)

**Status: PARKED.** Phase 1 of the clip flywheel (manual posting from the Post
Studio — "Top pick to post" + per-platform caption templates + download +
mark-posted) is **built and live**. Phase 2 is **direct API posting after human
review**, and it's gated on external account/app setup + platform approvals that
take real calendar time. The developer chose to finish the full app build +
design tweaks first; this is the reference for when they're ready.

**One timing note:** the long pole is **TikTok's API approval** (app review +
usually business verification, days-to-weeks). If you want to shorten the
eventual wait, you can kick off *just* the TikTok app registration early even
while the rest stays parked — the clock runs in the background.

**The non-negotiable that shapes the whole build:** every social post goes out
only after a **human (founder) review** of platform policy. A clip that's fine
under the app's free-speech policy can still get the marketing account
struck/banned by TikTok/IG/YT. So "auto-post" always means *auto AFTER the
founder's one-click approval*, never un-reviewed. (See CLAUDE.md → "SEAMLESS /
AUTOMATIC POSTING OF CLIPS TO SOCIALS" and "OFFICIAL-POST COMPLIANCE RULES".)

---

## 0. Prerequisites (shared)

- [ ] **Brand social accounts** (the accounts you post *from*):
  - [ ] **TikTok** — `@thebullyleague` is taken by an unrelated account, so use a
        variant (e.g. `@thebullyleague_official`, matching the IG handle decision).
  - [ ] **Instagram** — `@thebullyleague_official` (already decided in branding).
  - [ ] **YouTube** — a channel (`@thebullyleague` / `@bullyleague` appeared
        available at last check).
- [ ] **Business entity** — TikTok (and some IG flows) may require a *verified
      business* to post via API. This ties to the deferred LLC decision (use the
      existing LLC vs. form one) — see CLAUDE.md → "Business Entity Formation".
- [ ] **Secret storage** — each platform's OAuth tokens/secrets go in **Firebase
      config / Secret Manager**, server-side only, exactly like the Agora /
      Turnstile / Cloud Vision secrets. **Never in the client.**

---

## 1. TikTok — the long pole, start first (primary growth channel)

- [ ] Register at **developers.tiktok.com**.
- [ ] Create an app; request the **Content Posting API** scope
      (`video.publish` / `video.upload`).
- [ ] **Business verification + app review.** Expect a review process. Unaudited
      apps are typically limited to *private / self-only* posting until approved —
      this is the bottleneck, so start it early.
- [ ] Choose the mode:
  - **Direct Post** — publishes straight to the feed (higher approval bar).
  - **Upload (draft)** — drops the clip into the brand account's TikTok inbox to
    finish manually. **Lighter approval bar — a good first step** (the founder
    taps "post" inside TikTok; still way faster than download→upload).
- [ ] OAuth the brand TikTok account; store the **refresh token** server-side.

## 2. Instagram Reels — Meta Graph API

- [ ] **Meta (Facebook) Developer** account + a Meta app (developers.facebook.com).
- [ ] The IG account must be a **Professional (Business or Creator)** account,
      **linked to a Facebook Page**.
- [ ] Request permissions: `instagram_content_publish` (+ `instagram_basic`,
      `pages_show_list` / `pages_read_engagement`) — these need **Meta App Review**.
- [ ] Publishing is **2 API calls**: create a media container (video URL +
      caption) → publish the container. The video must be a **public URL** — our
      published-clip public URL works (the Post Studio already mints these).
- [ ] OAuth → a **long-lived Page access token**, stored server-side.

## 3. YouTube Shorts — Data API v3

- [ ] In the existing **Google Cloud project** (same one as Firebase) → enable
      **YouTube Data API v3** (one-time console toggle, same pattern as Cloud
      Vision / Speech-to-Text).
- [ ] Set up the **OAuth consent screen** + credentials; authorize the brand
      **YouTube channel**. Scope: `https://www.googleapis.com/auth/youtube.upload`.
- [ ] Upload via **`videos.insert`** (resumable upload). A Short is just a
      vertical video ≤ 3 min; `#Shorts` in the title/description is enough — our
      caption template already includes it.
- [ ] **Quota:** the default is ~10,000 units/day and an upload costs ~1,600, so
      ~6 uploads/day out of the box — fine to start; request more when needed.

---

## 4. The integration build (once ≥1 platform is authorized)

- [ ] Store each platform's tokens in server config.
- [ ] Add a **Cloud Function per platform** (or one with a provider switch) that
      takes a match's rendered clip URL + a caption and posts it.
- [ ] Hang it off the Post Studio's existing **review → post** flow: the
      per-clip **caption templates become the auto-filled caption**, and
      **"Mark posted" becomes the real post button** (one click, after the
      founder's review — the human gate stays).
- [ ] Track which clips went where (the per-platform tick state already exists;
      extend it to record real post IDs so nothing double-posts).
- [ ] **Easiest-first:** wire **YouTube or IG** first (more accessible APIs) as
      the proof; **TikTok** once approved — but prioritise TikTok's *approval
      timeline* since it's the primary channel.

---

## Sequencing summary
1. Create the 3 brand accounts (cheap — do anytime).
2. **Start TikTok app registration + business verification** (longest clock).
3. YouTube + IG app setup (faster).
4. Build the integration once at least one platform is authorized.
