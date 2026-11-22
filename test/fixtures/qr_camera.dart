import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:serverdeck/sync/sync_qr_camera.dart';

class FakeQrCamera implements SyncQrCameraDriver {
  Completer<void>? starting;
  bool failStart = false;
  int starts = 0, disposals = 0;
  ValueChanged<String>? detected;
  @override
  Future<void> start() async {
    starts++;
    if (starting != null) await starting!.future;
    if (failStart) throw StateError('synthetic private camera detail');
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  Widget preview(ValueChanged<String> onCode) {
    detected = onCode;
    return const Text('synthetic camera');
  }

  void send(String value) => detected?.call(value);
}
