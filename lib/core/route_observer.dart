import 'package:flutter/widgets.dart';

/// A single app-wide route observer, registered on the MaterialApp's
/// [navigatorObservers].
///
/// It exists so the looping video players ([LoopingVideo], [MatchClipPlayer])
/// can tell when another screen has been pushed on top of them and PAUSE -
/// not only when the whole app is backgrounded. Without this, an intro video
/// or a match clip keeps looping its audio underneath whatever you navigated
/// to, which a real device did audibly (2026-09-16: a match clip kept playing
/// the round audio after the player moved on).
///
/// Typed as [ModalRoute] rather than [PageRoute] on purpose, so it observes
/// BOTH full-screen page routes AND modal bottom sheets - the gauntlet
/// "Tonight's Field" study sheet is a modal, and it plays an intro out loud.
final RouteObserver<ModalRoute<dynamic>> appRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();
