import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/auth_service.dart';
import '../info/rules_screen.dart';
import 'appearance_screen.dart';
import 'blocked_players_screen.dart';
import 'notification_settings_screen.dart';

/// Account & settings, reached from the profile avatar in the Home header.
///
/// This is the ACCOUNT surface, deliberately distinct from the bottom
/// Profile tab, which is the player's PUBLIC profile (identity, form,
/// stats). Everything here is about managing the account: how it works,
/// notifications, appearance, and who you have blocked. Each entry reuses a
/// screen that already exists - this is a hub, not new machinery.
///
/// Sign out and Delete my account deliberately live on the Profile tab
/// (developer's call, 2026-09-17), NOT here - they were duplicated on this
/// menu and are not needed in both places.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

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
