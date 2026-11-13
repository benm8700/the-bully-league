import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'expiry_countdown.dart';
import 'neon_action_button.dart';

/// "X challenged you" - ONE card for every place an incoming friend
/// challenge shows (Home and the Roast a Friend screen), in the neon style
/// (2026-11-11). Before this, only the Accept button used the display font;
/// the name, the timer and Decline were plain body text on a grey card.
///
/// A dark glass card with a pink neon edge, an "INCOMING CHALLENGE" tag and a
/// countdown pill, the challenger's name big in the display serif, the
/// [NeonActionButton] to accept and a quiet outlined Decline.
class IncomingChallengeCard extends StatelessWidget {
  const IncomingChallengeCard({
    super.key,
    required this.fromUsername,
    required this.expiresAtMs,
    required this.onAccept,
    required this.onDecline,
    this.busy = false,
    this.acceptLabel = 'Accept',
    this.declineLabel = 'Decline',
  });

  final String fromUsername;
  final Object? expiresAtMs;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final bool busy;
  final String acceptLabel;
  final String declineLabel;

  static const _pink = Color(0xFFFF2E7E);
  static const _blue = Color(0xFF3D7BFF);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_pink, _blue],
        ),
        boxShadow: [
          BoxShadow(color: _pink.withValues(alpha: 0.35), blurRadius: 16),
          BoxShadow(
            color: _blue.withValues(alpha: 0.18),
            blurRadius: 30,
            spreadRadius: 1,
          ),
        ],
      ),
      padding: const EdgeInsets.all(1.8),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xF21A1024), Color(0xF20A0810)],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: _pill(
                      child: const Text(
                        '🔥 INCOMING CHALLENGE',
                        style: TextStyle(
                          color: _pink,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                      color: _pink,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Spacer(),
                _pill(
                  color: Colors.white,
                  child: ExpiryCountdown(
                    expiresAtMs: expiresAtMs,
                    prefix: '',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              fromUsername,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: p.display,
                color: Colors.white,
                fontSize: 22,
                height: 1.05,
                fontVariations: [
                  const FontVariation('wght', 800),
                  FontVariation('wdth', p.displayWidth),
                ],
                shadows: [
                  Shadow(color: _pink.withValues(alpha: 0.6), blurRadius: 14),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'wants to roast you. Strangers pick the winner.',
              style: TextStyle(
                fontFamily: p.display,
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 10),
            NeonActionButton(
              label: acceptLabel,
              icon: Icons.sports_mma_rounded,
              busy: busy,
              compact: true,
              onPressed: onAccept,
            ),
            const SizedBox(height: 2),
            Center(
              child: TextButton(
                onPressed: busy ? null : onDecline,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white60,
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                child: Text(declineLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _pill({required Widget child, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: child,
    );
  }
}

/// The SLIM Home banner for an incoming challenge (2026-11-11). Since the
/// challenge also gets a pop-up, the banner is just a reminder: one row with
/// the name, the countdown and a small ACCEPT pill. Tapping the row (not the
/// pill) reopens the full pop-up.
class IncomingChallengeStrip extends StatelessWidget {
  const IncomingChallengeStrip({
    super.key,
    required this.fromUsername,
    required this.expiresAtMs,
    required this.onAccept,
    required this.onOpen,
    this.busy = false,
  });

  final String fromUsername;
  final Object? expiresAtMs;
  final VoidCallback onAccept;
  final VoidCallback onOpen;
  final bool busy;

  static const _pink = Color(0xFFFF2E7E);
  static const _blue = Color(0xFF3D7BFF);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(colors: [_pink, _blue]),
        boxShadow: [
          BoxShadow(color: _pink.withValues(alpha: 0.3), blurRadius: 12),
        ],
      ),
      padding: const EdgeInsets.all(1.5),
      child: Material(
        color: const Color(0xF2140D1C),
        borderRadius: BorderRadius.circular(14.5),
        child: InkWell(
          borderRadius: BorderRadius.circular(14.5),
          onTap: busy ? null : onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                const Text('🔥', style: TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: fromUsername,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                            const TextSpan(
                              text: ' challenged you',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      ExpiryCountdown(
                        expiresAtMs: expiresAtMs,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: busy ? null : onAccept,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: const LinearGradient(
                        colors: [_pink, Color(0xFFC21FD8)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _pink.withValues(alpha: 0.5),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'ACCEPT',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A slim neon alert row for Home (2026-11-11): the same look as the
/// challenge strip, for "your battle is ready" and "you're in the queue".
/// [pillLabel] shows a lit pill button; null shows a chevron instead.
class NeonAlertStrip extends StatelessWidget {
  const NeonAlertStrip({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.pillLabel,
    required this.onTap,
    this.colors = const [Color(0xFFFF2E7E), Color(0xFF3D7BFF)],
    this.pulse = false,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final String? pillLabel;
  final VoidCallback onTap;

  /// Ring gradient; the first colour also drives the glow and the pill.
  final List<Color> colors;

  /// A stronger glow for urgent alerts (a battle waiting right now).
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final hot = colors.first;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(colors: colors),
        boxShadow: [
          BoxShadow(
            color: hot.withValues(alpha: pulse ? 0.5 : 0.25),
            blurRadius: pulse ? 18 : 10,
          ),
        ],
      ),
      padding: const EdgeInsets.all(1.5),
      child: Material(
        color: const Color(0xF2140D1C),
        borderRadius: BorderRadius.circular(14.5),
        child: InkWell(
          borderRadius: BorderRadius.circular(14.5),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Two lines allowed: "Someone took up your challenge"
                      // was cut to "Someone took..." beside the pill.
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          height: 1.15,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (pillLabel != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        colors: [hot, const Color(0xFFC21FD8)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: hot.withValues(alpha: 0.5),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: Text(
                      pillLabel!.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  )
                else
                  const Icon(Icons.chevron_right, color: Colors.white54),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
