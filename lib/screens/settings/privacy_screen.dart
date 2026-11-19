import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Privacy controls (2026-11-19). For now: whether people who already have
/// your number can find you through "Friends from contacts". On by default
/// (absent = on), like most apps; `contactDiscoverable: false` hides you from
/// every contact lookup (functions/contactMatch.js `visibleMatch`).
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final text = Theme.of(context).textTheme;
    if (uid == null) return const Scaffold();
    final ref = FirebaseFirestore.instance.collection('users').doc(uid);
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: ref.snapshots(),
        builder: (context, snap) {
          final on = snap.data?.data()?['contactDiscoverable'] != false;
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              SwitchListTile(
                value: on,
                onChanged: (v) => ref.set({
                  'contactDiscoverable': v,
                }, SetOptions(merge: true)),
                title: const Text('Let people who have my number find me'),
                subtitle: const Text(
                  'Friends who already have your number in their contacts '
                  'can see you are on The Bully League and challenge you.',
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  'Your phone number is never shown to anyone.',
                  style: text.bodySmall,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
