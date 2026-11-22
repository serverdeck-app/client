import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../runtime/permission_lifecycle.dart';

abstract interface class SyncQrCameraDriver {
  Future<void> start();
  Future<void> dispose();
  Widget preview(ValueChanged<String> onCode);
}

final class MobileSyncQrCameraDriver implements SyncQrCameraDriver {
  final _controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
    returnImage: false,
  );
  @override
  Future<void> start() async {
    await _controller.start();
    if (_controller.value.error != null || !_controller.value.isRunning) {
      throw StateError('Camera unavailable');
    }
  }

  @override
  Future<void> dispose() => _controller.dispose();
  @override
  Widget preview(ValueChanged<String> onCode) => MobileScanner(
    controller: _controller,
    onDetect: (capture) {
      if (capture.barcodes.length != 1) return;
      final code = capture.barcodes.single.rawValue;
      if (code != null) onCode(code);
    },
    onDetectError: (_, _) {},
    errorBuilder: (_, _) => const Text(
      'Камера недоступна. Можно ввести код восстановления вручную.',
    ),
  );
}

class SyncQrCamera extends StatefulWidget {
  const SyncQrCamera({
    super.key,
    required this.onCode,
    required this.onRetired,
    this.createDriver,
    this.permissionGate,
  });
  final ValueChanged<String> onCode;
  final VoidCallback onRetired;
  final SyncQrCameraDriver Function()? createDriver;
  final CameraPermissionGate? permissionGate;
  @override
  State<SyncQrCamera> createState() => _SyncQrCameraState();
}

class _SyncQrCameraState extends State<SyncQrCamera>
    with WidgetsBindingObserver {
  late final SyncQrCameraDriver _driver;
  CameraPermissionLease? _permission;
  bool _closed = false, _failed = false;
  @override
  void initState() {
    super.initState();
    _driver = widget.createDriver?.call() ?? MobileSyncQrCameraDriver();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_closed) unawaited(_start());
    });
  }

  Future<void> _start() async {
    try {
      _permission = (widget.permissionGate ?? CameraPermissionGate.shared)
          .begin(() => _retire(notify: true));
      await _driver.start();
      if (_closed) return;
    } catch (_) {
      if (!_closed && mounted) {
        _failed = true;
        setState(() {});
      }
      _disposeDriver();
    } finally {
      _permission?.complete(WidgetsBinding.instance.lifecycleState);
    }
  }

  bool _driverDisposed = false;
  void _disposeDriver() {
    if (_driverDisposed) return;
    _driverDisposed = true;
    unawaited(_driver.dispose().catchError((Object _) {}));
  }

  void _retire({required bool notify}) {
    if (_closed) return;
    _closed = true;
    _permission?.cancel();
    _disposeDriver();
    if (notify && mounted) widget.onRetired();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_closed) _permission?.complete(state);
      return;
    }
    if (state == AppLifecycleState.inactive && _permission?.active == true)
      return;
    _retire(notify: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retire(notify: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _failed
      ? const Text(
          'Камера недоступна или доступ запрещён. Введите код восстановления вручную.',
        )
      : SizedBox(
          height: 280,
          child: _driver.preview((value) {
            if (!_closed &&
                !_failed &&
                (WidgetsBinding.instance.lifecycleState == null ||
                    WidgetsBinding.instance.lifecycleState ==
                        AppLifecycleState.resumed))
              widget.onCode(value);
          }),
        );
}
