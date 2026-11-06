import 'package:age_range_signals/age_range_signals.dart';
import 'package:flutter/foundation.dart';

/// What the app store told us about the person signing up.
enum AgeCheckOutcome {
  /// The store reports an age range of 18 or over.
  adult,

  /// The store reports an age range under 18. Hard block - no account.
  minor,

  /// The store has no age for this person: not a covered region, they
  /// declined to share (where declining is allowed), an older OS, a
  /// sideloaded build, or any error. Most US users land here today. Signup
  /// continues and the person self-attests 18+ on the "Before you roast"
  /// screen, which every account must accept.
  noSignal,

  /// Android only: Play requires this person to verify their age in the Play
  /// Store app before it will share it (US states with app-store age laws).
  /// There is no in-app way to do it, so signup stops and points them there.
  verifyInStore,
}

/// Wraps the platform age signals (Google Play Age Signals on Android,
/// Apple's Declared Age Range on iOS 26+) so screens never touch the SDK.
/// Per CLAUDE.md, no birthdate is ever stored - only how the person was
/// cleared (see [AgeCheckOutcome] and the `ageAssurance` field written at
/// signup).
abstract class AgeVerificationService {
  Future<AgeCheckOutcome> check();
}

/// The real check, via the `age_range_signals` plugin. One gate at 18: the
/// app is adults-only, so "18 or over" is the only line that matters.
class PlatformAgeVerificationService implements AgeVerificationService {
  bool _initialized = false;

  @override
  Future<AgeCheckOutcome> check() async {
    final signals = AgeRangeSignals.instance;
    try {
      if (!_initialized) {
        await signals.initialize(ageGates: [18]);
        _initialized = true;
      }

      // On Android this can show Play's age-sharing sheet; on iOS it shows
      // nothing (Apple's sheet comes from checkAgeSignals below).
      final access = await signals.requestAgeSignalsAccess();
      if (access == AgeSignalsAccessStatus.verificationRequired) {
        return AgeCheckOutcome.verifyInStore;
      }
      if (access != AgeSignalsAccessStatus.shared) {
        return AgeCheckOutcome.noSignal;
      }

      final result = await signals.checkAgeSignals();

      // A reported range that tops out under 18 is a minor, whatever the
      // status says.
      final upper = result.ageUpper;
      if (upper != null && upper < 18) return AgeCheckOutcome.minor;

      switch (result.status) {
        case AgeSignalsStatus.verified:
          return AgeCheckOutcome.adult;
        case AgeSignalsStatus.supervised:
        case AgeSignalsStatus.supervisedApprovalPending:
        case AgeSignalsStatus.supervisedApprovalDenied:
          return AgeCheckOutcome.minor;
        default:
          // declined / unknown / anything new: no usable answer.
          return AgeCheckOutcome.noSignal;
      }
    } on AgeSignalsException catch (e) {
      // Unsupported OS, no Play Store, network, missing entitlement, user
      // closed the sheet... None of these say the person is a minor, so they
      // must never block signup - fall back to self-attestation.
      debugPrint('Age signals unavailable: ${e.message}');
      return AgeCheckOutcome.noSignal;
    } catch (e) {
      debugPrint('Age signals failed: $e');
      return AgeCheckOutcome.noSignal;
    }
  }
}

/// Always "no signal" - for tests and any environment without the plugin.
class StubAgeVerificationService implements AgeVerificationService {
  @override
  Future<AgeCheckOutcome> check() async => AgeCheckOutcome.noSignal;
}
