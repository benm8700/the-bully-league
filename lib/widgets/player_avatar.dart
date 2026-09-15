import 'package:flutter/material.dart';

/// A round player avatar: the real profile photo when there is one, else a
/// deterministic coloured circle with the player's initial so opponents stay
/// visually distinct even before photos are enabled (they are deferred for
/// the beta - see CLAUDE.md's User Profile System).
class PlayerAvatar extends StatelessWidget {
  const PlayerAvatar({
    super.key,
    required this.name,
    this.photoUrl,
    this.size = 40,
  });

  final String name;
  final String? photoUrl;
  final double size;

  static const List<Color> _fallbackColors = [
    Color(0xFF7C4DFF),
    Color(0xFF00897B),
    Color(0xFFC2185B),
    Color(0xFF3949AB),
    Color(0xFFEF6C00),
    Color(0xFF00838F),
  ];

  @override
  Widget build(BuildContext context) {
    if (photoUrl != null && photoUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: size / 2,
        backgroundImage: NetworkImage(photoUrl!),
      );
    }
    final trimmed = name.trim();
    final letter = trimmed.isNotEmpty ? trimmed[0].toUpperCase() : '?';
    final color = _fallbackColors[name.hashCode.abs() % _fallbackColors.length];
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color.withValues(alpha: 0.9),
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}
