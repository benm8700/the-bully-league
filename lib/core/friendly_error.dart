import 'package:cloud_functions/cloud_functions.dart';

/// Turns an exception into something a player can act on.
///
/// THIS EXISTS BECAUSE THE JUDGE TAB SHOWED A RAW DART STACK TRACE.
/// Six frames of `cloud_functions_platform_interface/pigeon/messages` were
/// rendered into the screen, under a heading, where a player was supposed
/// to be watching battles. It is useless to them, it is alarming, it
/// leaks the app's internals, and it is the sort of thing a store
/// reviewer or a beta tester remembers.
///
/// The rules here, which are the ones the app should follow everywhere:
/// say what happened, say what to do about it, and never apologise. An
/// error is a moment for direction, not mood.
///
/// The underlying exception is deliberately NOT included. A player cannot
/// use it, and the cases where it matters are cases where a developer
/// should be reading logs instead.
String friendlyError(Object error, {String? doing}) {
  final action = doing == null ? '' : ' $doing';

  if (error is FirebaseFunctionsException) {
    switch (error.code) {
      case 'unavailable':
      case 'deadline-exceeded':
      case 'internal':
        // By far the most common in practice, and the only one the player
        // can actually do something about.
        return 'Can\'t reach the league right now. Check your connection '
            'and try again.';
      case 'unauthenticated':
        return 'You have been signed out. Sign in again to carry on.';
      case 'permission-denied':
        return 'This account can\'t do that.';
      case 'resource-exhausted':
        // The server's own message is the useful one here - it is what
        // says WHICH allowance ran out.
        return error.message ?? 'You have used all of today\'s allowance.';
      default:
        // A server-authored message is written for a player; a code is
        // not. Prefer the message, fall back to something plain.
        return error.message ?? 'That didn\'t work$action. Try again.';
    }
  }

  return 'That didn\'t work$action. Try again.';
}
