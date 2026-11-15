import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/runtime/android_bootstrap.dart';
import 'package:serverdeck/runtime/android_platform.dart';
import 'package:serverdeck/runtime/android_runtime.dart';

const _epoch = '00000000-0000-4000-8000-000000000001';
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const channel = MethodChannel('test/mobile-runtime');
  test(
    'mobile adapter reports readiness and rejects unsupported desktop commands',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'initialize'
            ? {
                'version': 1,
                'platform': 'android',
                'ownerEpoch': _epoch,
                'dataRoot': '/data/user/0/com.unng.serverdeck/files/serverdeck',
              }
            : null;
      });
      final platform = AndroidPlatform(channel: channel);
      final runtime = AndroidRuntimePlatform(platform);
      addTearDown(() async {
        await runtime.closeActivation();
        await runtime.finishExit();
        await platform.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      final snapshot = await runtime.snapshot();
      expect(snapshot.epoch, _epoch);
      expect(snapshot.trayAvailable, isFalse);
      expect(snapshot.osEnding, isFalse);
      expect(() => runtime.hideToTray(), throwsUnsupportedError);
      expect(() => runtime.restore(), throwsUnsupportedError);
      expect(() => runtime.retryTray(), throwsUnsupportedError);
      expect(
        () => runtime.requestUpdateRestart('0.3.5'),
        throwsUnsupportedError,
      );
      expect(calls, ['initialize']);
    },
  );
  testWidgets(
    'mobile bootstrap shows safe initialization failure and retry before native DB',
    (tester) async {
      const native = MethodChannel('serverdeck/android');
      var initializes = 0;
      final pending = Completer<Object?>();
      messenger.setMockMethodCallHandler(native, (call) async {
        expect(call.method, 'initialize');
        initializes++;
        if (initializes == 1)
          throw PlatformException(
            code: 'STORAGE_IO',
            message: 'synthetic-private-path',
          );
        return pending.future;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(native, null));
      await tester.pumpWidget(const AndroidBootstrap());
      await tester.pump();
      expect(find.text('Данные недоступны'), findsOneWidget);
      expect(find.textContaining('synthetic-private-path'), findsNothing);
      await tester.tap(find.text('Повторить'));
      await tester.pump();
      expect(initializes, 2);
      expect(find.text('Открываем данные'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      pending.completeError(PlatformException(code: 'STORAGE_IO'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
