import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';

import 'visual_moderation_service.dart';

/// Calls the moderatePhoto/moderateMatchFrame Cloud Functions
/// (functions/visualModeration.js), which run Google Cloud Vision's
/// SafeSearch server-side - same "sensitive external calls go through
/// Cloud Functions" pattern as castVote's Turnstile verification, keeping
/// any provider credentials off the client.
class CloudVisionModerationService implements VisualModerationService {
  @override
  Future<String?> checkImage(String storagePath) async {
    final callable = FirebaseFunctions.instance.httpsCallable('moderatePhoto');
    final result = await callable.call<Map<String, dynamic>>({'storagePath': storagePath});
    return _reasonFromResult(result.data);
  }

  @override
  Future<String?> checkImageBytes(Uint8List jpegBytes) async {
    final callable = FirebaseFunctions.instance.httpsCallable('moderateMatchFrame');
    final result = await callable.call<Map<String, dynamic>>({
      'imageBase64': base64Encode(jpegBytes),
    });
    return _reasonFromResult(result.data);
  }

  String? _reasonFromResult(Map<String, dynamic> data) {
    final approved = data['approved'] as bool? ?? false;
    if (approved) return null;
    return data['reason'] as String? ?? 'Rejected by content moderation.';
  }
}
