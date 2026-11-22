import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/runtime/permission_lifecycle.dart';
import 'package:serverdeck/sync/sync_qr_camera.dart';

import '../fixtures/qr_camera.dart';

void main() {
  setUp(
    () => TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  testWidgets(
    'initial permission inactive preserves intent but frames wait for foreground',
    (tester) async {
      final camera = FakeQrCamera()..starting = Completer<void>();
      final gate = CameraPermissionGate();
      var retired = 0;
      final values = <String>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SyncQrCamera(
            createDriver: () => camera,
            permissionGate: gate,
            onCode: values.add,
            onRetired: () => retired++,
          ),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      camera.send('synthetic');
      expect(values, isEmpty);
      expect(retired, 0);
      camera.starting!.complete();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      camera.send('synthetic');
      expect(values, ['synthetic']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(camera.disposals, 1);
    },
  );
  testWidgets(
    'actual background disposes pending camera and rejects late grant/frame',
    (tester) async {
      final camera = FakeQrCamera()..starting = Completer<void>();
      var retired = 0, codes = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SyncQrCamera(
            createDriver: () => camera,
            permissionGate: CameraPermissionGate(),
            onCode: (_) => codes++,
            onRetired: () => retired++,
          ),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      camera.starting!.complete();
      await tester.pump();
      camera.send('late secret');
      expect(retired, 1);
      expect(codes, 0);
      expect(camera.disposals, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'denial exposes fixed manual fallback without native error detail',
    (tester) async {
      final camera = FakeQrCamera()..failStart = true;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SyncQrCamera(
            createDriver: () => camera,
            permissionGate: CameraPermissionGate(),
            onCode: (_) {},
            onRetired: () {},
          ),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('Введите код восстановления вручную'),
        findsOneWidget,
      );
      expect(find.textContaining('synthetic private'), findsNothing);
      expect(camera.disposals, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('startup permission has a finite30s lifetime', (tester) async {
    final camera = FakeQrCamera()..starting = Completer<void>();
    var retired = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SyncQrCamera(
          createDriver: () => camera,
          permissionGate: CameraPermissionGate(),
          onCode: (_) {},
          onRetired: () => retired++,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 30));
    expect(retired, 1);
    expect(camera.disposals, 1);
    camera.starting!.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
