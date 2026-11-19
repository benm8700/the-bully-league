import 'dart:async';

import 'package:permission_handler/permission_handler.dart';

/// Camera + mic access without hanging.
///
/// On iPhone the permission plugin's `request()` can never return even when
/// access is already granted (build 5, and again on build 10 2026-11-19,
/// when a 3-minute bound meant a 3-minute spinner on the pre-match check).
/// So: already granted -> no request at all; otherwise request, but also
/// re-read the status every second and return as soon as both are granted.
/// The long bound stays only for a person still looking at the OS "Allow?"
/// dialog. Throws [TimeoutException] if nothing resolves in time.
Future<Map<Permission, PermissionStatus>> requestCameraMic() async {
  Future<Map<Permission, PermissionStatus>> current() async => {
    Permission.camera: await Permission.camera.status,
    Permission.microphone: await Permission.microphone.status,
  };
  bool both(Map<Permission, PermissionStatus> s) =>
      (s[Permission.camera]?.isGranted ?? false) &&
      (s[Permission.microphone]?.isGranted ?? false);

  final before = await current().timeout(const Duration(seconds: 5));
  if (both(before)) return before;

  final done = Completer<Map<Permission, PermissionStatus>>();
  [Permission.camera, Permission.microphone].request().then(
    (s) {
      if (!done.isCompleted) done.complete(s);
    },
    onError: (Object e) {
      if (!done.isCompleted) done.completeError(e);
    },
  );
  final poll = Timer.periodic(const Duration(seconds: 1), (_) async {
    try {
      final s = await current();
      if (both(s) && !done.isCompleted) done.complete(s);
    } catch (_) {}
  });
  try {
    return await done.future.timeout(const Duration(minutes: 3));
  } finally {
    poll.cancel();
  }
}
