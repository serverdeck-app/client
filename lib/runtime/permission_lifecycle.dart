import 'dart:async';

import 'package:flutter/widgets.dart';

/// Narrow camera-start lease. Never suppresses actual background transitions.
final class CameraPermissionGate {
  static final shared = CameraPermissionGate();
  final _listeners = <VoidCallback>{};
  CameraPermissionLease? _lease;
  bool get active => _lease != null;
  void addListener(VoidCallback listener) => _listeners.add(listener);
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
  CameraPermissionLease begin(VoidCallback expired) {
    if (_lease != null)
      throw StateError('Camera permission request already active');
    final lease = CameraPermissionLease._(this);
    _lease = lease;
    lease._timer = Timer(const Duration(seconds: 30), () {
      if (!identical(_lease, lease)) return;
      _close(lease, notify: true);
      expired();
    });
    return lease;
  }

  bool preserveInactive(AppLifecycleState? state, bool wasResumed) {
    if ({
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    }.contains(state)) {
      final lease = _lease;
      if (lease != null) _close(lease, notify: false);
      return false;
    }
    if (state == AppLifecycleState.resumed && _lease?._completed == true) {
      _close(_lease!, notify: false);
    }
    return state == AppLifecycleState.inactive && wasResumed && active;
  }

  void _close(CameraPermissionLease lease, {required bool notify}) {
    if (!identical(_lease, lease)) return;
    _lease = null;
    lease._timer?.cancel();
    if (notify) {
      for (final listener in List.of(_listeners)) {
        listener();
      }
    }
  }
}

final class CameraPermissionLease {
  CameraPermissionLease._(this._gate);
  final CameraPermissionGate _gate;
  Timer? _timer;
  bool _completed = false;
  bool get active => identical(_gate._lease, this);
  void complete(AppLifecycleState? state) {
    _completed = true;
    if (state == null || state == AppLifecycleState.resumed)
      _gate._close(this, notify: false);
  }

  void cancel() => _gate._close(this, notify: true);
}
