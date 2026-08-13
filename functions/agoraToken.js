const {RtcTokenBuilder, RtcRole} = require("agora-token");

// Matches the App ID hardcoded in lib/core/config/agora_config.dart (the
// "The Bully League" Agora project) - hardcoded here too (not taken from
// the client request) so a client can't ask this function to mint a token
// for an arbitrary App ID.
const AGORA_APP_ID = "e5f9f9c0aa48408289d9e91456905955";

// Generous relative to an actual match's real length (pre-match check +
// bio reveal + 3 rounds is a few minutes, see CLAUDE.md's Match Structure
// section) - the token is freshly generated on every join anyway, so a
// long expiry here is just headroom, not a standing credential.
const TOKEN_EXPIRE_SECONDS = 3600;

/**
 * Builds a real, signed Agora RTC token for the given channel. uid 0 means
 * the token isn't bound to a specific uid - matches the client's existing
 * joinChannel(uid: 0) call, which lets Agora assign a uid dynamically (see
 * CLAUDE.md's Build Order step 4 host-election notes, which rely on that
 * Agora-assigned uid).
 */
function generateToken(appCertificate, channelName) {
  return RtcTokenBuilder.buildTokenWithUid(
      AGORA_APP_ID,
      appCertificate,
      channelName,
      0,
      RtcRole.PUBLISHER,
      TOKEN_EXPIRE_SECONDS,
      TOKEN_EXPIRE_SECONDS,
  );
}

module.exports = {generateToken, AGORA_APP_ID};
