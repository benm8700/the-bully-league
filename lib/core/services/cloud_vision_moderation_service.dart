import 'package:cloud_functions/cloud_functions.dart';

import 'visual_moderation_service.dart';

/// Calls the moderatePhoto Cloud Function (functions/visualModeration.js),
/// which runs Google Cloud Vision's SafeSearch on the image server-side -
/// same "sensitive external calls go through Cloud Functions" pattern as
/// castVote's Turnstile verification, keeping any provider credentials off
/// the client.
class CloudVisionModerationService implements VisualModerationService {
  @override
  Future<String?> checkImage(String storagePath) async {
    final callable = FirebaseFunctions.instance.httpsCallable('moderatePhoto');
    final result = await callable.call<Map<String, dynamic>>({'storagePath': storagePath});
    final approved = result.data['approved'] as bool? ?? false;
    if (approved) return null;
    return result.data['reason'] as String? ?? 'Rejected by content moderation.';
  }
}
