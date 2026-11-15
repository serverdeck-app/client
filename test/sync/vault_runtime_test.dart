import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/runtime/platform_ports.dart';
import 'package:serverdeck/sync/sync_http.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/sync/sync_recovery.dart';
import 'package:serverdeck/sync/sync_runtime.dart';
import 'package:serverdeck/sync/sync_transport.dart';
import 'package:serverdeck/sync/sync_cycle.dart';
import 'package:serverdeck/sync/sync_wire.dart';

import '../fixtures/feature_harness.dart';
import '../fixtures/sync_lifecycle.dart';
import 'transport_test.dart' as wire;

class _Life implements PlatformLifecyclePort {
  @override
  PlatformLifecyclePhase phase = PlatformLifecyclePhase.resumed;
  final controller = StreamController<PlatformLifecyclePhase>.broadcast(
    sync: true,
  );
  @override
  Stream<PlatformLifecyclePhase> get changes => controller.stream;
  void emit(PlatformLifecyclePhase next) {
    phase = next;
    controller.add(next);
  }
}

class _Secrets implements PlatformSecretPort {
  _Secrets(this.delegate);
  final PlatformSecretPort delegate;
  Completer<void>? hold;
  int unprotects = 0;
  @override
  Future<Uint8List> protect(Uint8List bytes, String purpose) =>
      delegate.protect(bytes, purpose);
  @override
  Future<Uint8List> unprotect(Uint8List bytes, String purpose) async {
    unprotects++;
    if (unprotects == 4) await hold?.future;
    return delegate.unprotect(bytes, purpose);
  }
}

class _Harness {
  final h = LifecycleHarness(), life = _Life();
  late final SyncRuntime runtime;
  late final _Secrets secrets;
  late final Map<String, Object?> head;
  late List<int> rootBytes;
  int failures = 0, retryAfter = 5;
  bool admitted = true, clockFails = false;
  Completer<SyncHttpResponse?>? hold;
  Future<void> setup() async {
    await h.setup();
    await h.lifecycle.dispose();
    h.owner.dispose();
    secrets = _Secrets(h.secrets);
    final remote = await h.local.remote(const [], revision: 1);
    await h.local.feature.repository.write((r) {
      final root = r.syncRoot(remote.rootId)!..role = 'base';
      r.putSyncRoot(root);
      final state = r.syncState
        ..baseRootId = remote.rootId
        ..candidateRootId = null
        ..baseRevision = 1;
      r.putSyncState(state);
    });
    head = {
      'vault_id': h.local.fence.identity.vaultId,
      'revision': 1,
      'manifest': remote.manifest.toJson(),
    };
    rootBytes = h
        .local
        .feature
        .repository
        .state
        .syncRoots[remote.rootId]!
        .manifestCiphertext
        .toList();
    h.handler = (request) async {
      if (request.uri.path == '/v1/vault/head') {
        if (hold != null) {
          final pending = hold!;
          hold = null;
          return pending.future;
        }
        if (failures > 0) {
          failures--;
          return wire.jsonResponse(
            {
              'error': 'storage_unavailable',
              'request_id': featureId(600),
              'retry_after_seconds': retryAfter,
            },
            status: 503,
            headers: {
              'content-type': ['application/json'],
              'retry-after': ['$retryAfter'],
            },
          );
        }
        return wire.jsonResponse(head);
      }
      if (request.uri.path.startsWith('/v1/vault/blobs/'))
        return SyncHttpResponse(200, {
          'content-type': ['application/octet-stream'],
          'content-length': ['${rootBytes.length}'],
        }, Stream.value(rootBytes));
      return null;
    };
    runtime = SyncRuntime(
      domain: h.local.feature.repository,
      gate: h.local.feature.gate,
      actor: h.local.feature.actors.owner,
      connections: h.local.batches,
      secrets: secrets,
      inspector: h.local.feature.parser,
      browser: h.browser,
      availableStorageBytes: () async => 100 * 1024 * 1024 * 1024,
      newId: h.local.feature.newId,
      utcNow: h.local.feature.clock.now,
      monotonicMicros: () {
        if (clockFails) throw StateError('clock');
        return h.local.feature.clock.elapsed.inMicroseconds;
      },
      schedule: h.local.feature.clock.schedule,
      transport: (origin) => SyncTransport(origin: origin, http: h.http),
      lifecycle: life,
      refreshClock: () async {},
      isRunning: () => admitted,
    );
  }

  Future<void> start() async {
    await runtime.initialize();
    runtime.activate();
  }

  Future<void> tick([int seconds = 0]) async {
    h.local.feature.clock.advance(Duration(seconds: seconds));
    await featureTurns(32);
  }

  int get heads => h.count('/v1/vault/head');
  Future<void> dispose() async {
    await runtime.dispose();
    await life.controller.close();
    await h.dispose();
  }
}

void main() {
  late _Harness h;
  setUp(() async {
    h = _Harness();
    await h.setup();
  });
  tearDown(() async => h.dispose());
  test('explicit inspect/cancel after resume owns the key even while old native unprotect is pending', () async {
    final native = Completer<void>();
    h.secrets.hold = native;
    await h.start();
    await h.tick();
    h.life.emit(PlatformLifecyclePhase.paused);
    h.life.emit(PlatformLifecyclePhase.resumed);
    await featureTurns();
    final uiHead = Completer<SyncHttpResponse?>();
    h.hold = uiHead;
    var cancelled = false;
    final explicit = h.runtime.owner.vault.inspect().then<void>(
      (_) {},
      onError: (Object _) {
        cancelled = true;
      },
    );
    await featureTurns();
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.checking);
    h.runtime.owner.vault.lock();
    native.complete();
    await explicit;
    await featureTurns();
    await h.tick(60);
    expect(cancelled, isTrue);
    expect(h.heads, 2);
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.unavailable);
    expect(h.runtime.cycle.view.phase, isNot(SyncCyclePhase.synced));
    uiHead.complete(wire.jsonResponse(h.head));
    await featureTurns();
    expect(h.heads, 2);
  });
  test('explicit key cancellation owns its generation and is not undone by root retry', () async {
    final held = Completer<void>();
    h.secrets.hold = held;
    await h.start();
    await h.tick();
    h.runtime.owner.vault.lock();
    held.complete();
    await featureTurns();
    await h.tick(60);
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.unavailable);
    expect(h.heads, 1);
  });
  test('revocation during platform key restoration rejects late key and stops retries', () async {
    final held = Completer<void>();
    h.secrets.hold = held;
    await h.start();
    await h.tick();
    h.h.status = 'revoked';
    await h.runtime.owner.checkDeviceStatus();
    held.complete();
    await featureTurns();
    await h.tick(60);
    expect(h.runtime.owner.view.phase, SyncAuthPhase.revoked);
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.unavailable);
    expect(h.heads, 1);
  });
  test('successful explicit reauthorization also restores an existing protected key without settings', () async {
    await h.start();
    await h.tick();
    h.h.nextDevice = h.h.local.fence.identity.deviceId;
    await h.runtime.owner.beginLogin(
      origin: SyncServiceOrigin(h.h.local.fence.identity.serviceOrigin),
      platform: 'android',
      name: 'Phone',
    );
    await h.tick(5);
    await h.tick();
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.ready);
    expect(h.runtime.cycle.view.phase, SyncCyclePhase.synced);
  });
  test('huge Retry-After uses bounded chunks without overflow or an early head request', () async {
    h.failures = 1;
    h.retryAfter = 9007199254740991;
    await h.start();
    await h.tick();
    await h.tick(300);
    await h.tick(300);
    expect(h.heads, 1);
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.error);
    final active = h.h.local.feature.clock.timers.where(
      (timer) => !timer.cancelled,
    );
    expect(active.length, 1);
    expect(
      active.single.at - h.h.local.feature.clock.elapsed,
      const Duration(seconds: 300),
    );
  });
  test('clock failure in optional key timer pauses sync safely and explicit calibrated retry recovers', () async {
    await h.start();
    h.clockFails = true;
    await h.tick();
    expect(h.heads, 0);
    expect(h.runtime.foregroundError, 'SYNC_RESUME_UNAVAILABLE');
    expect(h.runtime.owner.view.phase, SyncAuthPhase.paused);
    h.clockFails = false;
    await h.runtime.retryForeground();
    await h.tick();
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.ready);
  });
  test('late platform unprotect from old foreground cannot unlock but latest foreground is rearmed', () async {
    final held = Completer<void>();
    h.secrets.hold = held;
    await h.start();
    await h.tick();
    expect(h.secrets.unprotects, 4);
    h.life.emit(PlatformLifecyclePhase.paused);
    h.life.emit(PlatformLifecyclePhase.resumed);
    await featureTurns();
    await h.tick();
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.unavailable);
    held.complete();
    await featureTurns();
    await h.tick();
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.ready);
    expect(h.runtime.cycle.view.phase, SyncCyclePhase.synced);
  });
  test('shutdown drain waits for cancelled platform key operation and never admits late key', () async {
    final held = Completer<void>();
    h.secrets.hold = held;
    await h.start();
    await h.tick();
    await h.runtime.stopAdmission();
    var drained = false;
    final draining = h.runtime.drain().then((_) => drained = true);
    await featureTurns();
    expect(drained, isFalse);
    held.complete();
    await draining;
    await h.tick(60);
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.unavailable);
    expect(h.heads, 1);
  });
  test('saved session/key resumes verified cycle without settings or startup network wait', () async {
    await h.start();
    expect(h.heads, 0);
    expect(h.runtime.owner.view.phase, SyncAuthPhase.signedIn);
    await h.tick();
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.ready);
    expect(h.runtime.cycle.view.phase, SyncCyclePhase.synced);
    final heads = h.heads;
    await h.tick(60);
    expect(h.heads, greaterThan(heads));
    expect(h.h.browser.pages, isEmpty);
  });
  test(
    'real foreground pause locks key; resume restores it and rechecks cycle',
    () async {
      await h.start();
      await h.tick();
      h.life.emit(PlatformLifecyclePhase.paused);
      expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.unavailable);
      final heads = h.heads;
      await h.tick(100);
      expect(h.heads, heads);
      h.life.emit(PlatformLifecyclePhase.resumed);
      await featureTurns();
      await h.tick();
      expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.ready);
      expect(h.runtime.cycle.view.phase, SyncCyclePhase.synced);
      expect(h.heads, greaterThan(heads));
    },
  );
  test('transient key inspection honors backoff and Retry-After then automatically resumes', () async {
    h.failures = 2;
    h.retryAfter = 7;
    await h.start();
    await h.tick();
    expect(h.heads, 1);
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.error);
    expect(h.runtime.owner.vault.view.errorCode, 'storage_unavailable');
    await h.tick(6);
    expect(h.heads, 1);
    await h.tick(1);
    expect(h.heads, 2);
    await h.tick(9);
    expect(h.heads, 2);
    await h.tick(1);
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.ready);
    expect(h.runtime.cycle.view.phase, SyncCyclePhase.synced);
  });
  test('pause cancels key retry timer but preserves cooldown for foreground return', () async {
    h.failures = 1;
    h.retryAfter = 20;
    await h.start();
    await h.tick();
    h.life.emit(PlatformLifecyclePhase.paused);
    await h.tick(5);
    h.life.emit(PlatformLifecyclePhase.resumed);
    await featureTurns();
    await h.tick();
    expect(h.heads, 1);
    await h.tick(14);
    expect(h.heads, 1);
    await h.tick(1);
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.ready);
  });
  test(
    'missing saved key leaves initialization and recovery explicit',
    () async {
      await h.h.local.feature.repository.write(
        (r) => r.putSyncSecrets(r.syncSecrets..protectedVaultRootKey = null),
      );
      await h.start();
      await h.tick(60);
      expect(h.heads, 0);
      expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.unavailable);
      expect(h.runtime.cycle.view.phase, isNot(SyncCyclePhase.synced));
    },
  );
  test('tampered remote key proof preserves saved key/data and has no automatic retry', () async {
    h.rootBytes = [...h.rootBytes]..[30] ^= 1;
    final before = h
        .h
        .local
        .feature
        .repository
        .state
        .syncSecrets
        .protectedVaultRootKey!
        .toList();
    await h.start();
    await h.tick();
    final heads = h.heads;
    await h.tick(300);
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.error);
    expect(h.heads, heads);
    expect(
      h.h.local.feature.repository.state.syncSecrets.protectedVaultRootKey,
      before,
    );
    expect(h.runtime.cycle.view.phase, isNot(SyncCyclePhase.synced));
  });
  test(
    'late cancelled key inspection cannot block latest foreground restoration',
    () async {
      final pending = Completer<SyncHttpResponse?>();
      h.hold = pending;
      await h.start();
      await h.tick();
      h.life.emit(PlatformLifecyclePhase.paused);
      h.life.emit(PlatformLifecyclePhase.resumed);
      await featureTurns();
      pending.complete(wire.jsonResponse(h.head));
      await featureTurns();
      await h.tick();
      expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.ready);
      expect(h.runtime.cycle.view.phase, SyncCyclePhase.synced);
    },
  );
  test('stop before activation timer prevents optional network after local shutdown', () async {
    await h.start();
    await h.runtime.stopAdmission();
    await h.tick(60);
    expect(h.heads, 0);
    expect(h.runtime.owner.vault.view.phase, SyncVaultPhase.unavailable);
  });
}
