import 'package:flutter/material.dart';

/// A quick exit to Home for deep, PUSHED screens that stack over the
/// bottom-nav tabs (the tournament flow especially) and hide the nav bar.
///
/// Pops every pushed route back to the app shell in one tap, so a player deep
/// in tournaments lands back on the tabs instead of backing out screen by
/// screen (developer's call, 2026-09-16). Deliberately NOT used on the five
/// bottom tabs themselves - those are already one tap from home.
///
/// Renders nothing when there is nothing to pop (e.g. if a screen is ever
/// shown as a root), so it can be dropped into an app bar unconditionally.
class HomeActionButton extends StatelessWidget {
  const HomeActionButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Navigator.of(context).canPop()) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(Icons.home_outlined),
      tooltip: 'Home',
      onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
    );
  }
}
