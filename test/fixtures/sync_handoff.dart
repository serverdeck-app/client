import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:serverdeck/runtime/platform_ports.dart';
import 'package:serverdeck/sync/sync_http.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/sync/sync_repository.dart';
import 'package:serverdeck/sync/sync_transport.dart';

import 'domain_repository.dart';
import '../sync/device_auth_test.dart' as auth;
import '../sync/transport_test.dart' as wire;

class HandoffBrowser implements PlatformBrowserPort {
  final pages = <Uri>[];
  void Function()? onOpen;
  Completer<void>? hold;
  bool fail = false;
  @override
  Future<void> openServicePage({
    required Uri serviceOrigin,
    required Uri page,
  }) async {
    pages.add(page);
    onOpen?.call();
    await hold?.future;
    if (fail) throw StateError('private browser error');
  }
}

class HandoffHarness {
  HandoffHarness(this.clock) {
    repository = SyncRepository(
      domain,
      availableStorageBytes: () async => 100 * 1024 * 1024 * 1024,
    );
    http = wire.FakeHttp((request, _) async {
      final custom = await handler?.call(request);
      if (custom != null) return custom;
      return switch (request.uri.path) {
        '/v1/device-authorizations' => wire.jsonResponse(
          wire.authorization(),
          status: 201,
        ),
        '/v1/device-token' => wire.jsonResponse(wire.session()),
        _ => throw StateError('unexpected synthetic request'),
      };
    });
    owner = SyncOwner(
      repository: repository,
      secrets: secrets,
      browser: browser,
      transport: (origin) => SyncTransport(origin: origin, http: http),
      monotonicMicros: () => clock.elapsed.inMicroseconds,
    );
  }
  final FakeAsync clock;
  final domain = MemoryDomainRepository();
  final secrets = auth.SecretPort();
  final browser = HandoffBrowser();
  late final SyncRepository repository;
  late final wire.FakeHttp http;
  late final SyncOwner owner;
  final errors = <Object>[];
  Future<SyncHttpResponse?> Function(SyncHttpRequest)? handler;
  void begin({String platform = 'android'}) {
    owner
        .beginLogin(origin: wire.origin, platform: platform, name: 'Device')
        .then<void>(
          (_) {},
          onError: (Object error) {
            errors.add(error);
          },
        );
    clock.flushMicrotasks();
  }

  void resume() {
    owner.resume().then<void>(
      (_) {},
      onError: (Object error) {
        errors.add(error);
      },
    );
    clock.flushMicrotasks();
  }

  int count(String path) =>
      http.requests.where((r) => r.uri.path == path).length;
  int get timers =>
      clock.pendingTimers.where((timer) => !timer.isPeriodic).length;
  void dispose() {
    owner.dispose();
    clock.flushMicrotasks();
  }
}
