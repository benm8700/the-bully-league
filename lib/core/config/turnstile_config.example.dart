/// Copy this file to turnstile_config.dart (gitignored) and fill in your
/// own Cloudflare Turnstile site key from https://dash.cloudflare.com/
/// (Turnstile section). The SECRET key never goes here - it lives only in
/// the Cloud Function (functions/index.js), set via
/// `firebase functions:secrets:set`.
const String turnstileSiteKey = 'YOUR_TURNSTILE_SITE_KEY';
