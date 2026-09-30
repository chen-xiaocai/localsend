import 'package:logging/logging.dart';

final _logger = Logger('StartupTimer');

/// Measures how long each startup step takes.
///
/// Every [mark] logs the duration of the step since the previous mark and the
/// total time since [start], e.g. `startup step=RustLib.init stepMs=85 totalMs=120`.
/// Filter the log with `adb logcat | grep "startup step"`.
class StartupTimer {
  static final Stopwatch _total = Stopwatch();
  static final Stopwatch _step = Stopwatch();

  static void start() {
    _total
      ..reset()
      ..start();
    _step
      ..reset()
      ..start();
  }

  static void mark(String step) {
    if (!_total.isRunning) {
      return;
    }
    _logger.info('startup step=$step stepMs=${_step.elapsedMilliseconds} totalMs=${_total.elapsedMilliseconds}');
    _step
      ..reset()
      ..start();
  }
}
