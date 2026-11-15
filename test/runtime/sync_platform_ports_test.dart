import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/runtime/native_platform.dart';
import 'package:serverdeck/runtime/platform_ports.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const channel = MethodChannel('test/sync/windows-ports');
  late NativePlatform platform;
  late List<MethodCall> calls;
  Object? free = 12345;
  setUp(() {
    calls = [];
    platform = NativePlatform(epoch: 'synthetic-owner', channel: channel);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'storage.availableBytes' ? free : null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('Windows browser port sends only captured public origin/page', () async {
    for (final suffix in [
      '/devices',
      '/account',
      '/activate',
      '/activate?user_code=ABCDEFGHJK',
    ]) {
      await platform.openServicePage(
        serviceOrigin: Uri.parse('https://sync.test:8443'),
        page: Uri.parse('https://sync.test:8443$suffix'),
      );
    }
    expect(calls.length, 4);
    for (final call in calls) {
      expect(call.method, 'browser.openServicePage');
      final args = call.arguments as Map;
      expect(args.keys.toSet(), {'ownerEpoch', 'origin', 'page'});
      expect(args['origin'], 'https://sync.test:8443');
    }
    expect(platform, isA<PlatformBrowserPort>());
    expect(platform, isA<PlatformStoragePort>());
  });
  test('browser port refuses cross origin, secret query and unexpected paths before channel', () {
    for (final target in [
      'https://other.test/devices',
      'https://sync.test/devices?token=synthetic',
      'https://sync.test/account#secret',
      'https://sync.test/activate?user_code=ABCDEFGHJI',
      'https://sync.test/activate?user_code=ABCDEFGHJK&token=synthetic',
      'https://sync.test/%2fdevices',
      'file:///devices',
    ]) {
      expect(
        () => platform.openServicePage(
          serviceOrigin: Uri.parse('https://sync.test'),
          page: Uri.parse(target),
        ),
        throwsFormatException,
      );
    }
    expect(calls, isEmpty);
  });
  test(
    'storage availability accepts only bounded nonnegative integer reply',
    () async {
      for (final value in [0, 12345, 9007199254740991]) {
        free = value;
        expect(await platform.availableStorageBytes(), value);
      }
      for (final value in [null, -1, 1.0, '123', 9007199254740992]) {
        free = value;
        await expectLater(
          platform.availableStorageBytes(),
          throwsFormatException,
        );
      }
    },
  );
}
