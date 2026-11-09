// TEST-ONLY entrypoint: starts the real app with Flutter Driver enabled so
// the simulator can be driven remotely during automated QA. Never used for
// release builds (those build lib/main.dart).
import 'package:flutter_driver/driver_extension.dart';
import 'package:bully_league/main.dart' as app;

void main() {
  enableFlutterDriverExtension();
  app.main();
}
