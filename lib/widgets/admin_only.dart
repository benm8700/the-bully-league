import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Shows its child only to an admin account.
///
/// WHY THIS EXISTS, and why it is not `kDebugMode`. Several admin tools -
/// force-finalizing a match, creating a tournament, advancing a bracket -
/// are reachable from ordinary screens, and they were visible to
/// everybody. The server already refuses them (`requireAdmin` checks the
/// caller's own `isAdmin` field), so this was never a security hole. It
/// was a WORSE problem than that in the only way that matters for a
/// private beta: a tester taps "Create Test Tournament", gets told "Admin
/// only", and concludes the app is broken. Buttons that exist and cannot
/// work are how a build feels unfinished.
///
/// `kDebugMode` was the obvious alternative and is wrong here: this
/// project's own testing runs in RELEASE builds on a device, so hiding
/// these in release would take the tools away from the person who needs
/// them. Gating on the same flag the server gates on means there is one
/// definition of "admin" rather than two that can disagree.
///
/// FAILS CLOSED. An unreadable flag renders nothing, because the failure
/// being fixed is showing these to a non-admin; an admin who loses a
/// button to a transient read can reopen the screen. `isAdmin` is written
/// as `false` at signup and is protected by firestore.rules, so it is only
/// ever true because someone set it by hand in the Firebase console -
/// which is the same admin workflow used for profile approval and report
/// review.
class AdminOnly extends StatefulWidget {
  const AdminOnly({super.key, required this.child});

  final Widget child;

  @override
  State<AdminOnly> createState() => _AdminOnlyState();
}

class _AdminOnlyState extends State<AdminOnly> {
  /// Cached per uid for the life of the process. These controls appear on
  /// several screens and the answer cannot change without a console edit,
  /// so re-reading the user document every time one is built is pure
  /// waste on a document already read on nearly every screen.
  static final Map<String, Future<bool>> _cache = {};

  Future<bool>? _isAdmin;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _isAdmin = _cache.putIfAbsent(uid, () async {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get();
        return snap.data()?['isAdmin'] == true;
      } catch (_) {
        return false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final future = _isAdmin;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<bool>(
      future: future,
      builder: (context, snapshot) =>
          snapshot.data == true ? widget.child : const SizedBox.shrink(),
    );
  }
}
