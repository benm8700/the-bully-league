import 'package:cloud_functions/cloud_functions.dart';

/// Fetches a real, per-join Agora RTC token from the generateAgoraToken
/// Cloud Function (functions/agoraToken.js) - replaces the hardcoded 24h
/// temp token used during early Build Order testing. Server-side because
/// the App Certificate needed to sign the token can never be shipped to
/// the client, same "sensitive external calls go through Cloud Functions"
/// pattern as castVote's Turnstile check.
Future<String> fetchAgoraToken(String channelName) async {
  final callable = FirebaseFunctions.instance.httpsCallable('generateAgoraToken');
  final result = await callable.call<Map<String, dynamic>>({'channelName': channelName});
  return result.data['token'] as String;
}
