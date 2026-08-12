/// Wraps age-bracket verification so the real Google Play Age Signals API
/// (and Apple's Declared Age Range API, once iOS is built) can be dropped in
/// later without touching call sites. See CLAUDE.md "Age Verification".
abstract class AgeVerificationService {
  /// Returns true if the signal indicates the user is 18+.
  /// Per CLAUDE.md, only this boolean is ever persisted — never a birthdate.
  Future<bool> isAdult();
}

/// Stub used until the developer's Play Console app listing exists and the
/// real Play Age Signals API (beta) can be wired in. Always reports 18+ so
/// the signup flow is testable end-to-end before that dependency is ready.
class StubAgeVerificationService implements AgeVerificationService {
  @override
  Future<bool> isAdult() async => true;
}
