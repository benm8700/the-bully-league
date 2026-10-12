import 'package:cloud_functions/cloud_functions.dart';

/// Thin wrapper over the Main Stage HUB callables (weekly chat + the judge
/// opt-in). The week the chat/judge state belongs to is derived server-side
/// from the clock (getHubRoom), so the client never picks it.
class HubService {
  static final FirebaseFunctions _fns = FirebaseFunctions.instance;

  /// The current hub week key (this qualifying week's Thursday), used to read
  /// the weekly chat room and the caller's judge-volunteer doc. Null on error -
  /// callers degrade to a neutral "opens with the Main Stage" state.
  static Future<String?> getHubRoom() async {
    try {
      final r = await _fns.httpsCallable('getHubRoom').call<Map<dynamic, dynamic>>({});
      final w = r.data['weekKey'];
      return w is String && w.isNotEmpty ? w : null;
    } catch (_) {
      return null;
    }
  }

  /// Post an ordinary message to this week's hub lobby. Rethrows
  /// FirebaseFunctionsException so the composer can surface e.message
  /// (moderation / rate-limit reasons).
  static Future<void> postMessage(String text) async {
    await _fns.httpsCallable('postHubMessage').call<Map<dynamic, dynamic>>({
      'text': text,
    });
  }

  /// Pin an announcement (admin/founder only - the server enforces it).
  static Future<void> postAnnouncement(String text) async {
    await _fns
        .httpsCallable('postHubAnnouncement')
        .call<Map<dynamic, dynamic>>({'text': text});
  }

  /// Opt in/out of judging this week's Main Stage. Returns the new state.
  static Future<bool> volunteerToJudge(bool opt) async {
    final r = await _fns
        .httpsCallable('volunteerToJudge')
        .call<Map<dynamic, dynamic>>({'opt': opt});
    return r.data['volunteered'] == true;
  }
}
