import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/auth_service.dart';
import '../../core/services/push_notification_service.dart';
import '../account/delete_account_screen.dart';
import '../info/rules_screen.dart';
import 'appearance_screen.dart';
import 'blocked_players_screen.dart';
import 'notification_settings_screen.dart';

/// Account & settings, reached from the profile avatar in the Home header.
///
/// This is the ACCOUNT surface, deliberately distinct from the bottom
/// Profile tab, which is the player's PUBLIC profile (identity, form,
/// stats). Everything here is about managing the account itself:
/// notifications, appearance, who you have blocked, signing out, and
/// deleting the account. Each entry reuses a screen that already exists -
/// this is a hub, not new machinery.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _signingOut = false;

  /// Best-effort: a failure to clean up the push token must not trap
  /// someone in an account they are trying to leave, so sign-out proceeds
  /// regardless. Mirrors the profile screen's sign-out.
  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    final push = context.read<PushNotificationService>();
    final auth = context.read<AuthService>();
    try {
      await push.unregister();
    } catch (_) {
      // Intentionally ignored - see above.
    }
    await auth.signOut();
    // No setState after: signing out swaps this whole tree out via AuthGate.
  }

  @override
  Widget build(BuildContext context) {
    final email = context.read<AuthService>().currentUser?.email;
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (email != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                email,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          // "How it works" moved here from Home (developer's call, 2026-09-14):
          // it sits under the account, one level in, rather than taking a slot
          // on Home. Opens the rules + the interactive "how a battle works"
          // demo + support.
          _tile(
            context,
            icon: Icons.menu_book_outlined,
            label: 'How it works',
            onTap: () => _push(context, const RulesScreen()),
          ),
          _tile(
            context,
            icon: Icons.notifications_outlined,
            label: 'Notifications',
            onTap: () => _push(context, const NotificationSettingsScreen()),
          ),
          _tile(
            context,
            icon: Icons.palette_outlined,
            label: 'Appearance',
            onTap: () => _push(context, const AppearanceScreen()),
          ),
          _tile(
            context,
            icon: Icons.block,
            label: 'Blocked players',
            onTap: () => _push(context, const BlockedPlayersScreen()),
          ),
          const Divider(height: 28),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: OutlinedButton.icon(
              onPressed: _signingOut ? null : _signOut,
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Sign out'),
            ),
          ),
          // CCPA requires a user-facing account/data deletion path (see
          // CLAUDE.md Compliance / Account Management). Kept quiet.
          Center(
            child: TextButton(
              onPressed: () => _push(context, const DeleteAccountScreen()),
              child: const Text(
                'Delete my account',
                style: TextStyle(color: Color(0xFFE05252)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Widget _tile(BuildContext context,
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
