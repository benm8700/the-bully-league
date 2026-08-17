import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// A notice the developer can put in front of every user from the Firebase
/// console (CLAUDE.md's Service Status & Reliability decision).
///
/// WHAT IT IS ACTUALLY FOR. This app has two hard third-party
/// dependencies - Agora for video and Firebase for everything else - and
/// when either has an outage the app does not report an outage, it just
/// fails: matchmaking finds nobody, a match will not connect, the feed is
/// empty. To a tester that is indistinguishable from a broken app, and
/// the rational response to a broken app is to stop opening it. One line
/// saying "we know, it is us" is the difference between a bad evening and
/// a lost user, and during a private beta with a handful of friends every
/// one of them matters.
///
/// It doubles as the only broadcast channel the app has - "no Sixes and
/// Sevens tonight", "new build on TestFlight" - which otherwise means
/// texting people individually.
///
/// THE FAILURE MODE OF A MANUAL BANNER IS FORGETTING TO TURN IT OFF, and
/// a stale "we are having problems" notice is worse than none at all: it
/// makes a working app look broken, and it teaches people to ignore the
/// banner, which costs you the one time it matters. So `expiresAtMs` is
/// honoured client-side and a banner without one is capped at 24 hours.
/// Switching it off is the console edit you might forget; expiring is the
/// one you cannot.
///
/// Renders NOTHING whenever anything is ambiguous - missing document,
/// unreadable, disabled, expired, empty message. Same rule as the live
/// online count: a status banner that is ever wrong is worse than absent.
class ServiceStatusBanner extends StatelessWidget {
  const ServiceStatusBanner({super.key});

  /// A banner with no explicit expiry disappears after this long. Long
  /// enough to outlast a real outage, short enough that a forgotten one
  /// does not become permanent furniture.
  static const _defaultLifetime = Duration(hours: 24);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('config')
          .doc('serviceStatus')
          .snapshots(),
      builder: (context, snapshot) {
        final status = ServiceStatus.fromMap(snapshot.data?.data());
        if (status == null || !status.isLiveAt(DateTime.now())) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        final (bg, fg, icon) = switch (status.severity) {
          'outage' => (scheme.errorContainer, scheme.onErrorContainer,
            Icons.cloud_off_outlined),
          'warning' => (scheme.tertiaryContainer, scheme.onTertiaryContainer,
            Icons.warning_amber_outlined),
          _ => (scheme.secondaryContainer, scheme.onSecondaryContainer,
            Icons.info_outline),
        };
        return Material(
          color: bg,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      status.message,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: fg),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The parsed notice. Separated from the widget so the rules that decide
/// whether anything is shown can be tested without a Firestore or a
/// widget tree - these are the rules that keep a stale banner off the
/// screen, and they are worth pinning.
class ServiceStatus {
  const ServiceStatus({
    required this.message,
    required this.severity,
    required this.expiresAt,
  });

  final String message;
  final String severity;
  final DateTime expiresAt;

  static const _severities = {'info', 'warning', 'outage'};

  /// The longest a message may be. A banner is a headline, not a status
  /// page - anything longer pushes the app off the screen on a small
  /// device, which is a self-inflicted outage of its own.
  static const _maxMessageLength = 200;

  /// Bounds-checked per field, because this document is hand-edited in the
  /// console against a live app with nothing validating it in between -
  /// the same rule the match settings, the event window and the username
  /// policy follow.
  ///
  /// Returns null rather than a partly-sane object whenever the notice
  /// cannot be shown honestly.
  static ServiceStatus? fromMap(Map<String, dynamic>? data) {
    if (data == null) return null;
    if (data['active'] != true) return null;

    final message = (data['message'] as String? ?? '').trim();
    if (message.isEmpty) return null;

    final severityRaw = (data['severity'] as String? ?? 'info').toLowerCase();
    final severity =
        _severities.contains(severityRaw) ? severityRaw : 'info';

    // An explicit expiry wins; otherwise the notice expires a fixed time
    // after it was last edited, so forgetting to switch it off cannot
    // leave it up forever.
    final explicit = data['expiresAtMs'];
    if (explicit is num && explicit > 0) {
      return ServiceStatus(
        message: message.length > _maxMessageLength
            ? '${message.substring(0, _maxMessageLength)}...'
            : message,
        severity: severity,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(explicit.toInt()),
      );
    }
    final updated = data['updatedAtMs'];
    final base = updated is num && updated > 0
        ? DateTime.fromMillisecondsSinceEpoch(updated.toInt())
        // No timestamp at all: treat it as expiring immediately rather
        // than as fresh. A notice nobody can date is a notice nobody
        // should trust.
        : null;
    if (base == null) return null;
    return ServiceStatus(
      message: message.length > _maxMessageLength
          ? '${message.substring(0, _maxMessageLength)}...'
          : message,
      severity: severity,
      expiresAt: base.add(ServiceStatusBanner._defaultLifetime),
    );
  }

  bool isLiveAt(DateTime now) => now.isBefore(expiresAt);
}
