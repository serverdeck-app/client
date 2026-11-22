import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/runtime/permission_lifecycle.dart';

void main() {
  test('only explicit starting lease preserves foreground inactive', () {
    fakeAsync((clock) {
      final gate = CameraPermissionGate();
      expect(gate.preserveInactive(AppLifecycleState.inactive, true), isFalse);
      final lease = gate.begin(() {});
      expect(gate.preserveInactive(AppLifecycleState.inactive, true), isTrue);
      expect(gate.preserveInactive(AppLifecycleState.inactive, false), isFalse);
      lease.complete(AppLifecycleState.inactive);
      expect(gate.active, isTrue);
      gate.preserveInactive(AppLifecycleState.resumed, true);
      expect(gate.active, isFalse);
    });
  });
  test('real background revokes lease even while permission/start pending', () {
    fakeAsync((clock) {
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        final gate = CameraPermissionGate();
        final lease = gate.begin(() {});
        expect(gate.preserveInactive(state, true), isFalse);
        expect(lease.active, isFalse);
      }
    });
  });
  test('timeout is bounded and notifies lifecycle recheck and scanner exactly once', () {
    fakeAsync((clock) {
      final gate = CameraPermissionGate();
      var rechecks = 0, expired = 0;
      gate.addListener(() => rechecks++);
      final lease = gate.begin(() => expired++);
      clock.elapse(const Duration(seconds: 30));
      expect(gate.active, isFalse);
      expect(rechecks, 1);
      expect(expired, 1);
      lease.cancel();
      clock.elapse(const Duration(seconds: 30));
      expect(rechecks, 1);
      expect(expired, 1);
    });
  });
  test('completed foreground and cancellation release the lease without stale close', () {
    fakeAsync((clock) {
      final gate = CameraPermissionGate();
      final first = gate.begin(() {});
      first.complete(AppLifecycleState.resumed);
      final second = gate.begin(() {});
      first.cancel();
      expect(second.active, isTrue);
      second.cancel();
      expect(gate.active, isFalse);
    });
  });
}
