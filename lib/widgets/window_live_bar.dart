import 'package:flutter/material.dart';

import '../app.dart';
import '../screens/tournament/tournament_list_screen.dart';
import '../theme/app_theme.dart';

/// A loud, app-wide "LIVE" bar shown only while Sixes and Sevens is on.
///
/// The deliberate REPLACEMENT for the old app-wide Nightlife skin swap
/// (dropped 2026-08-31): rather than repaint the whole app - which read as a
/// different app to anyone opening fresh during the window, and undercut the
/// Comedy Night brand - the app keeps its identity and gains one loud "the
/// show is ON" signal. It is meant to GRAB: a solid red bar (the `live`
/// token, distinct from the pink primary), a glinting shine sweep, a blinking
/// LIVE badge, the 2x-points hook, and a JOIN pill that reads as a button.
///
/// Mounted in MainShell above the tabs, so it follows the viewer across every
/// tab the way the event feeling used to, and costs a zero-height widget the
/// rest of the day.
class WindowLiveBar extends StatefulWidget {
  const WindowLiveBar({super.key});

  @override
  State<WindowLiveBar> createState() => _WindowLiveBarState();
}

class _WindowLiveBarState extends State<WindowLiveBar>
    with TickerProviderStateMixin {
  // The blinking LIVE dot.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..repeat(reverse: true);

  // The shine that sweeps across the whole bar.
  late final AnimationController _shine = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    _shine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: kWindowLive,
      builder: (context, live, _) {
        if (!live) return const SizedBox.shrink();
        final palette = context.palette;
        final red = palette.live;
        // The app draws edge-to-edge, so pad content below the status bar and
        // let the red fill up behind it - reads like a coloured status bar.
        final topInset = MediaQuery.of(context).padding.top;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const TournamentListScreen()),
            ),
            child: Stack(
              children: [
                // Base: a vivid red gradient with a soft glow beneath.
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        const Color(0xFFC81232),
                        red,
                        const Color(0xFFC81232),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: red.withValues(alpha: 0.55),
                        blurRadius: 12,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  padding: EdgeInsets.only(
                      left: 14, right: 12, top: topInset + 9, bottom: 9),
                  child: _content(context),
                ),
                // The shine sweep, over everything, ignoring taps.
                Positioned.fill(
                  child: IgnorePointer(
                    child: ClipRect(
                      child: AnimatedBuilder(
                        animation: _shine,
                        builder: (context, _) {
                          final t = _shine.value; // 0..1, then a pause
                          // Slide a narrow bright band left to right; the
                          // gap in the 0..1 loop is the pause between glints.
                          final x = -1.0 + 3.2 * t;
                          return DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment(x - 0.28, -0.6),
                                end: Alignment(x + 0.28, 0.6),
                                colors: [
                                  Colors.white.withValues(alpha: 0),
                                  Colors.white.withValues(alpha: 0.35),
                                  Colors.white.withValues(alpha: 0),
                                ],
                                stops: const [0.0, 0.5, 1.0],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _content(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        // The blinking LIVE badge.
        FadeTransition(
          opacity: Tween<double>(begin: 0.35, end: 1).animate(_pulse),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                      color: Colors.white, shape: BoxShape.circle),
                ),
                const SizedBox(width: 5),
                Text('LIVE',
                    style: text.labelSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    )),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Name + the 2x hook.
        Expanded(
          child: ValueListenableBuilder<String>(
            valueListenable: kWindowName,
            builder: (context, name, _) => Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: '${name.toUpperCase()}  ',
                  style: text.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.3,
                  ),
                ),
                TextSpan(
                  text: '· 2X POINTS',
                  style: text.labelSmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // The JOIN pill - reads as a button.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('JOIN',
                  style: text.labelLarge?.copyWith(
                    color: const Color(0xFFC81232),
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  )),
              const Icon(Icons.chevron_right,
                  size: 16, color: Color(0xFFC81232)),
            ],
          ),
        ),
      ],
    );
  }
}
