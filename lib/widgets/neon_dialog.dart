import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// THE NEON POP-UP (2026-11-11, developer: "make sure they ALL look like the
/// new cool one"). A drop-in replacement for [AlertDialog] - same title /
/// content / actions / icon API - so every stock pop-up in the app is this
/// one look: a dark glass card inside a pink-to-blue neon ring with a glow,
/// the title in the display serif, and the action buttons restyled in place:
/// a FilledButton becomes the lit pink gradient pill (the NeonActionButton
/// look), a TextButton a quiet white label, an OutlinedButton a neon outline.
///
/// `backgroundColor` and `shape` are accepted and ignored so existing call
/// sites compile unchanged.
class NeonDialog extends StatelessWidget {
  const NeonDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.icon,
    this.actionsAlignment,
    this.backgroundColor,
    this.shape,
    this.surfaceTintColor,
    this.contentPadding,
    this.titlePadding,
    this.actionsPadding,
    this.scrollable = false,
    this.accent = pink,
  });

  // Accepted for AlertDialog compatibility; the neon look sets its own.
  final Color? surfaceTintColor;
  final EdgeInsetsGeometry? contentPadding;
  final EdgeInsetsGeometry? titlePadding;
  final EdgeInsetsGeometry? actionsPadding;
  final bool scrollable;

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final Widget? icon;
  final MainAxisAlignment? actionsAlignment;
  final Color? backgroundColor;
  final ShapeBorder? shape;

  /// The ring and glow colour (pink by default).
  final Color accent;

  static const pink = Color(0xFFFF2E7E);
  static const blue = Color(0xFF3D7BFF);
  static const magenta = Color(0xFFC21FD8);

  /// Button styles used inside every neon pop-up and sheet.
  static ThemeData buttonTheme(BuildContext context, {bool gold = false}) {
    final base = Theme.of(context);
    final hot = gold ? const Color(0xFFF8C73B) : pink;
    final deep = gold ? const Color(0xFFD98A12) : magenta;
    final label = gold ? const Color(0xFF241500) : Colors.white;
    final p = context.palette;
    return base.copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 46)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 20),
          ),
          foregroundColor: WidgetStatePropertyAll(label),
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          textStyle: WidgetStatePropertyAll(
            TextStyle(
              fontFamily: p.display,
              fontSize: 15,
              letterSpacing: 0.8,
              fontVariations: [
                const FontVariation('wght', 800),
                FontVariation('wdth', p.displayWidth),
              ],
            ),
          ),
          backgroundBuilder: (context, states, child) {
            final disabled = states.contains(WidgetState.disabled);
            return DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: LinearGradient(
                  colors: disabled
                      ? const [Color(0xFF3A3242), Color(0xFF2C2534)]
                      : [hot, deep],
                ),
                boxShadow: disabled
                    ? null
                    : [
                        BoxShadow(
                          color: hot.withValues(alpha: 0.5),
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ],
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.22),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                    stops: const [0, 0.55],
                  ),
                ),
                child: child,
              ),
            );
          },
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: Colors.white70,
          minimumSize: const Size(0, 46),
          textStyle: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 46),
          shape: const StadiumBorder(),
          side: BorderSide(color: hot.withValues(alpha: 0.7), width: 1.4),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Theme(
        data: buttonTheme(context),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [accent, blue],
            ),
            boxShadow: [
              BoxShadow(color: accent.withValues(alpha: 0.38), blurRadius: 22),
              BoxShadow(
                color: blue.withValues(alpha: 0.2),
                blurRadius: 40,
                spreadRadius: 2,
              ),
            ],
          ),
          padding: const EdgeInsets.all(1.8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFA1C1226), Color(0xFA0B0911)],
                ),
              ),
              child: Stack(
                children: [
                  // Glass gloss along the top.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 60,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: 0.08),
                              Colors.white.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (icon != null) ...[
                          Center(
                            child: IconTheme(
                              data: IconThemeData(
                                color: accent,
                                size: 34,
                                shadows: [
                                  Shadow(color: accent, blurRadius: 14),
                                ],
                              ),
                              child: icon!,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (title != null)
                          DefaultTextStyle(
                            textAlign: icon != null
                                ? TextAlign.center
                                : TextAlign.start,
                            style: TextStyle(
                              fontFamily: p.display,
                              color: Colors.white,
                              fontSize: 22,
                              height: 1.15,
                              fontVariations: [
                                const FontVariation('wght', 800),
                                FontVariation('wdth', p.displayWidth),
                              ],
                              shadows: [
                                Shadow(
                                  color: accent.withValues(alpha: 0.55),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                            child: title!,
                          ),
                        if (content != null) ...[
                          const SizedBox(height: 10),
                          Flexible(
                            child: SingleChildScrollView(
                              child: DefaultTextStyle(
                                style: (text.bodyMedium ?? const TextStyle())
                                    .copyWith(
                                      color: Colors.white.withValues(
                                        alpha: 0.78,
                                      ),
                                      height: 1.4,
                                    ),
                                child: content!,
                              ),
                            ),
                          ),
                        ],
                        if (actions != null && actions!.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Wrap(
                            alignment: switch (actionsAlignment) {
                              MainAxisAlignment.center => WrapAlignment.center,
                              MainAxisAlignment.start => WrapAlignment.start,
                              MainAxisAlignment.spaceBetween =>
                                WrapAlignment.spaceBetween,
                              _ => WrapAlignment.end,
                            },
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: actions!,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Drop-in for [showModalBottomSheet] (2026-11-11 neon pass): the sheet gets
/// the global neon sheet look (theme), and every button inside it gets the
/// NeonDialog button styles - a FilledButton becomes the lit pink pill, or a
/// GOLD pill when [gold] is true (reward surfaces, e.g. Free Rewards).
/// Plain ListTile actions (Block, Report) are untouched on purpose.
Future<T?> showNeonSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool gold = false,
  bool showDragHandle = false,
  bool isScrollControlled = false,
  bool isDismissible = true,
  Color? backgroundColor,
  ShapeBorder? shape,
}) {
  const goldEdge = Color(0xFFF8C73B);
  return showModalBottomSheet<T>(
    context: context,
    // A gold sheet draws its own gold handle (the theme's handle is pink).
    showDragHandle: showDragHandle && !gold,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    backgroundColor: backgroundColor,
    shape:
        shape ??
        (gold
            ? const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
                side: BorderSide(color: Color(0xCCF8C73B), width: 1.5),
              )
            : null),
    builder: (sheetContext) => Theme(
      data: NeonDialog.buttonTheme(sheetContext, gold: gold),
      child: gold && showDragHandle
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 14, bottom: 4),
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: goldEdge,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Flexible(child: Builder(builder: builder)),
              ],
            )
          : Builder(builder: builder),
    ),
  );
}
