import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/runtime/android_platform.dart';
import 'package:serverdeck/runtime/platform_ports.dart';
import 'package:serverdeck/runtime/permission_lifecycle.dart';
import 'package:serverdeck/storage/store_manifest.dart';

const epoch = '00000000-0000-4000-8000-000000000001';
const root = '/data/user/0/com.unng.serverdeck/files/serverdeck';
const channel = MethodChannel('test/serverdeck/android');
Map<String, Object?> context() => {
  'version': 1,
  'ownerEpoch': epoch,
  'dataRoot': root,
  'platform': 'android',
};
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late AndroidPlatform platform;
  late CameraPermissionGate permissionGate;
  late List<MethodCall> calls;
  Future<Object?> Function(MethodCall)? handler;
  setUp(() {
    calls = [];
    handler = null;
    permissionGate = CameraPermissionGate();
    platform = AndroidPlatform(
      channel: channel,
      cameraPermissionGate: permissionGate,
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (handler != null) return handler!(call);
      return switch (call.method) {
        'initialize' => context(),
        'storage.availableBytes' => 123456,
        'secret.protect' => Uint8List.fromList([1, 2, 3]),
        'secret.unprotect' => Uint8List.fromList([7, 8, 9]),
        'credential.pickKey' => null,
        _ => null,
      };
    });
  });
  tearDown(() async {
    handler = null;
    await platform.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });
  test('camera startup permission preserves only inactive foreground, real pause still propagates', () async {
    await platform.prepareStorage();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final lease = permissionGate.begin(() {});
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(platform.phase, PlatformLifecyclePhase.resumed);
    lease.complete(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(permissionGate.active, isFalse);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(platform.phase, PlatformLifecyclePhase.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    permissionGate.begin(() {});
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(permissionGate.active, isFalse);
    expect(platform.phase, PlatformLifecyclePhase.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  });
  test('single initializer captures private root/epoch and Android capability policy', () async {
    final results = await Future.wait([
      platform.prepareStorage(),
      platform.prepareStorage(),
    ]);
    expect(calls.where((c) => c.method == 'initialize').length, 1);
    expect(results.first, isA<BundledLibraryStorageLocation>());
    expect(results.first.dataRoot, root);
    expect(platform.epoch, epoch);
    expect(platform.capabilities, PlatformCapabilities.android);
    expect(platform.capabilities.supportsMcp, isFalse);
    expect(platform.capabilities.supportsMonitoring, isFalse);
    expect(await platform.availableStorageBytes(), 123456);
    for (final call in calls.where((c) => c.method != 'initialize')) {
      expect((call.arguments as Map)['ownerEpoch'], epoch);
      expect((call.arguments as Map)['version'], 1);
    }
  });
  test(
    'bad initialization schema or root is rejected without admitting commands',
    () async {
      for (final bad in [
        {...context(), 'version': 2},
        {...context(), 'version': 1.0},
        {...context(), 'ownerEpoch': 'bad'},
        {...context(), 'dataRoot': 'relative/data'},
        {...context(), 'dataRoot': '/data/../outside'},
        {...context(), 'unexpected': true},
      ]) {
        handler = (call) async => call.method == 'initialize' ? bad : null;
        await expectLater(
          platform.prepareStorage(),
          throwsA(isA<AndroidPlatformFailure>()),
        );
      }
      expect(calls.every((c) => c.method == 'initialize'), isTrue);
    },
  );
  test(
    'binary replies are owned writable copies and borrowed inputs stay intact',
    () async {
      final input = Uint8List.fromList([23, 24]);
      final protected = await platform.protect(
        input,
        'credential.v1:synthetic',
      );
      protected.fillRange(0, protected.length, 0);
      expect(input, [23, 24]);
      final clear = await platform.unprotect(input, 'credential.v1:synthetic');
      clear.fillRange(0, clear.length, 0);
      expect(input, [23, 24]);
    },
  );
  test(
    'input bounds and purpose validation happen before native admission',
    () async {
      for (final purpose in ['', 'a' * 129, 'bad\u0000', '非ASCII']) {
        await expectLater(
          platform.protect(Uint8List(1), purpose),
          throwsA(isA<AndroidPlatformFailure>()),
        );
      }
      await expectLater(
        platform.protect(Uint8List(1048577), 'valid'),
        throwsA(isA<AndroidPlatformFailure>()),
      );
      await expectLater(
        platform.unprotect(Uint8List(2097153), 'valid'),
        throwsA(isA<AndroidPlatformFailure>()),
      );
      expect(calls, isEmpty);
    },
  );
  test('binary and disk replies are strictly typed and bounded; raw native errors stay private', () async {
    handler = (call) async => switch (call.method) {
      'initialize' => context(),
      'secret.protect' => Uint8List(2097153),
      'secret.unprotect' => 'private-data',
      'storage.availableBytes' => -1,
      _ => null,
    };
    await expectLater(
      platform.protect(Uint8List(1), 'valid'),
      throwsA(isA<AndroidPlatformFailure>()),
    );
    await expectLater(
      platform.unprotect(Uint8List(1), 'valid'),
      throwsA(isA<AndroidPlatformFailure>()),
    );
    await expectLater(
      platform.availableStorageBytes(),
      throwsA(isA<AndroidPlatformFailure>()),
    );
    handler = (call) async => throw PlatformException(
      code: 'RAW-SECRET',
      message: 'private-native-error',
    );
    try {
      await platform.availableStorageBytes();
      fail('expected failure');
    } catch (e) {
      expect(e.toString(), isNot(contains('private-native-error')));
      expect(e.toString(), isNot(contains('RAW-SECRET')));
    }
  });
  test(
    'browser allows only captured canonical origin and fixed paths',
    () async {
      for (final page in [
        'https://other.test/devices',
        'http://sync.test/devices',
        'https://sync.test/devices?token=private',
        'https://sync.test/%2Fdevices',
      ]) {
        await expectLater(
          platform.openServicePage(
            serviceOrigin: Uri.parse('https://sync.test'),
            page: Uri.parse(page),
          ),
          throwsA(isA<AndroidPlatformFailure>()),
        );
      }
      expect(calls, isEmpty);
      await platform.openServicePage(
        serviceOrigin: Uri.parse('https://sync.test'),
        page: Uri.parse('https://sync.test/activate?user_code=ABCDEFGHJK'),
      );
      expect(calls.last.method, 'browser.open');
      expect(
        (calls.last.arguments as Map)['page'],
        'https://sync.test/activate?user_code=ABCDEFGHJK',
      );
    },
  );
  test('picker cancellation is null, duplicate call is blocked and late bytes are cancelled', () async {
    expect(await platform.pickPrivateKey(), isNull);
    final reply = Completer<Object?>();
    handler = (call) async =>
        call.method == 'credential.pickKey' ? reply.future : null;
    final pick = platform.pickPrivateKey();
    final failed = expectLater(pick, throwsA(isA<AndroidPlatformFailure>()));
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      platform.pickPrivateKey(),
      throwsA(isA<AndroidPlatformFailure>()),
    );
    await platform.cancelPending();
    reply.complete(Uint8List.fromList([19]));
    await failed;
  });
  test('metadata commands reject arbitrary paths and noncanonical publication bytes', () async {
    final bytes = StoreManifest(epoch).encode();
    for (final path in [
      '../outside',
      '/absolute/path',
      'data/publish/not-an-id',
    ]) {
      await expectLater(
        platform.flushAtomic(path, bytes),
        throwsA(isA<AndroidPlatformFailure>()),
      );
    }
    await expectLater(
      platform.flushAtomic('data/publish/$epoch', Uint8List(1)),
      throwsA(isA<AndroidPlatformFailure>()),
    );
    expect(calls, isEmpty);
    await platform.flushAtomic('data/flush/$epoch', Uint8List(0));
    await platform.flushAtomic('data/publish/$epoch', bytes);
    expect(calls.where((c) => c.method == 'file.flushAtomic').length, 2);
  });
  test(
    'stop/drain reject late results and no new native commands are admitted',
    () async {
      await platform.prepareStorage();
      final reply = Completer<Object?>();
      handler = (call) async =>
          call.method == 'secret.protect' ? reply.future : null;
      final protecting = platform.protect(Uint8List(1), 'valid');
      final failed = expectLater(
        protecting,
        throwsA(isA<AndroidPlatformFailure>()),
      );
      await Future<void>.delayed(Duration.zero);
      await platform.stopAdmission();
      reply.complete(Uint8List.fromList([4, 5]));
      await failed;
      await platform.drain();
      final before = calls.length;
      await expectLater(
        platform.availableStorageBytes(),
        throwsA(isA<AndroidPlatformFailure>()),
      );
      expect(calls.length, before);
      expect(calls.last.method, 'platform.drain');
    },
  );
  test('cancelling picker before initialization completes cannot launch a late system picker', () async {
    final initialized = Completer<Object?>();
    handler = (call) async =>
        call.method == 'initialize' ? initialized.future : null;
    final pick = platform.pickPrivateKey();
    final failed = expectLater(pick, throwsA(isA<AndroidPlatformFailure>()));
    await Future<void>.delayed(Duration.zero);
    await platform.cancelPending();
    initialized.complete(context());
    await failed;
    expect(calls.where((c) => c.method == 'credential.pickKey'), isEmpty);
  });
  test('shutdown during initialization adopts context only to drain and release native lease', () async {
    final initialized = Completer<Object?>();
    handler = (call) async =>
        call.method == 'initialize' ? initialized.future : null;
    final starting = platform.prepareStorage();
    final failed = expectLater(
      starting,
      throwsA(isA<AndroidPlatformFailure>()),
    );
    await Future<void>.delayed(Duration.zero);
    final shutdown = platform.dispose();
    initialized.complete(context());
    await failed;
    await shutdown;
    expect(calls.map((c) => c.method), [
      'initialize',
      'platform.stopAdmission',
      'platform.drain',
      'platform.dispose',
    ]);
  });
  test('lifecycle reports platform state without a desktop channel', () async {
    await platform.prepareStorage();
    final seen = <PlatformLifecyclePhase>[];
    final subscription = platform.changes.listen(seen.add);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(platform.phase, PlatformLifecyclePhase.resumed);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(platform.phase, PlatformLifecyclePhase.paused);
    expect(
      seen,
      containsAll([
        PlatformLifecyclePhase.resumed,
        PlatformLifecyclePhase.paused,
      ]),
    );
    await subscription.cancel();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  test(
    'read-only codec binary view is copied before consumer zeroization',
    () async {
      const codec = StandardMethodCodec();
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMessageHandler(channel.name, (message) async {
        final call = codec.decodeMethodCall(message!);
        return codec
            .encodeSuccessEnvelope(
              call.method == 'initialize'
                  ? context()
                  : call.method == 'secret.unprotect'
                  ? Uint8List.fromList([21, 31])
                  : null,
            )
            .asUnmodifiableView();
      });
      final bytes = await platform.unprotect(Uint8List(1), 'valid');
      expect(bytes, [21, 31]);
      bytes.fillRange(0, bytes.length, 0);
      await platform.dispose();
      messenger.setMockMessageHandler(channel.name, null);
    },
  );
  test(
    'cached storage preparation cannot return as admitted after stop',
    () async {
      await platform.prepareStorage();
      final reading = platform.prepareStorage();
      final failed = expectLater(
        reading,
        throwsA(isA<AndroidPlatformFailure>()),
      );
      await platform.stopAdmission();
      await failed;
      await platform.drain();
    },
  );
  test(
    'paused lifecycle subscriber cannot block native resource disposal',
    () async {
      await platform.prepareStorage();
      final subscription = platform.changes.listen((_) {});
      subscription.pause();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await platform.dispose();
      expect(calls.last.method, 'platform.dispose');
      await subscription.cancel();
    },
  );
  test(
    '32 operation backpressure rejects before another native secret call',
    () async {
      await platform.prepareStorage();
      final released = Completer<Object?>();
      handler = (call) async =>
          call.method == 'secret.protect' ? released.future : null;
      final pending = [
        for (var i = 0; i < 32; i++) platform.protect(Uint8List(1), 'valid'),
      ];
      await expectLater(
        platform.protect(Uint8List(1), 'valid'),
        throwsA(isA<AndroidPlatformFailure>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'secret.protect').length, 32);
      released.complete(Uint8List.fromList([1]));
      for (final bytes in await Future.wait(pending)) {
        bytes.fillRange(0, bytes.length, 0);
      }
    },
  );
  test(
    'Android monotonic clock adds bounded sleep without a background timer',
    () async {
      await platform.dispose();
      var awake = 0, callsToClock = 0;
      final replies = <Map<String, int>>[
        {'lowerMicros': 1000, 'upperMicros': 2000},
        {'lowerMicros': 600001000, 'upperMicros': 600002000},
        {'lowerMicros': 600002000, 'upperMicros': 600003000},
      ];
      platform = AndroidPlatform(channel: channel, awakeMicros: () => awake);
      handler = (call) async => switch (call.method) {
        'initialize' => context(),
        'clock.sleepBounds' => replies[callsToClock++],
        _ => null,
      };
      expect(platform.monotonicMicros, throwsA(isA<AndroidPlatformFailure>()));
      await platform.refreshMonotonicClock();
      expect(platform.monotonicMicros(), 0);
      awake = 5000000;
      final before = platform.monotonicMicros();
      await platform.refreshMonotonicClock();
      expect(
        platform.monotonicMicros() - before,
        greaterThanOrEqualTo(600000000),
      );
      final same = platform.monotonicMicros();
      await platform.refreshMonotonicClock();
      expect(platform.monotonicMicros(), greaterThanOrEqualTo(same));
      awake = 1;
      expect(platform.monotonicMicros, throwsA(isA<AndroidPlatformFailure>()));
    },
  );
  test('clock sampling is single flight and malformed native bounds never become time', () async {
    final reply = Completer<Object?>();
    handler = (call) async => call.method == 'initialize'
        ? context()
        : call.method == 'clock.sleepBounds'
        ? reply.future
        : null;
    final a = platform.refreshMonotonicClock(),
        b = platform.refreshMonotonicClock();
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c.method == 'clock.sleepBounds').length, 1);
    reply.complete({'lowerMicros': 2, 'upperMicros': 1});
    await expectLater(
      Future.wait([a, b]),
      throwsA(isA<AndroidPlatformFailure>()),
    );
    expect(platform.monotonicMicros, throwsA(isA<AndroidPlatformFailure>()));
  });
  test(
    'new foreground cannot reuse clock sample captured before suspension',
    () async {
      var samples = 0;
      final old = Completer<Object?>();
      handler = (call) async {
        if (call.method == 'initialize') return context();
        if (call.method == 'clock.sleepBounds') {
          samples++;
          if (samples == 2) return old.future;
          return {
            'lowerMicros': samples == 1 ? 0 : 600000000,
            'upperMicros': samples == 1 ? 0 : 600000000,
          };
        }
        return null;
      };
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await platform.refreshMonotonicClock();
      final previous = platform.refreshMonotonicClock();
      final cancelled = expectLater(
        previous,
        throwsA(isA<AndroidPlatformFailure>()),
      );
      await Future<void>.delayed(Duration.zero);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final latest = platform.refreshMonotonicClock();
      old.complete({'lowerMicros': 0, 'upperMicros': 0});
      await cancelled;
      await latest;
      expect(samples, 3);
      expect(platform.monotonicMicros(), greaterThanOrEqualTo(600000000));
    },
  );
}
