import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_cycle.dart';
import 'package:serverdeck/sync/sync_apply.dart';
import 'package:serverdeck/sync/sync_atomic_apply.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_merge.dart';
import 'package:serverdeck/sync/sync_transport.dart';

import '../fixtures/feature_harness.dart';
import '../fixtures/software_card.dart';
import '../fixtures/sync_cycle.dart';
import '../fixtures/sync_merge.dart';
import 'device_auth_test.dart' as auth;
import 'credential_transfer_test.dart' show Inspector;
import 'transport_test.dart' as wire;

void main() {
  late CycleHarness h;
  setUp(() async {
    h = CycleHarness();
    await h.setup();
  });
  tearDown(() => h.dispose());
  Future<void> turns() => featureTurns(80);

  test('real snapshot builder captures legacy boundary card into synthetic encrypted cycle', () async {
    final domain = h.apply.feature.repository.state;
    final card = legacyMaxCard(
      domain.profiles[h.localId]!,
      h.apply.feature.newId(),
    );
    domain.softwareCards[card.softwareId] = card;
    await h.cycle.resume();
    await turns();
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(
      h
          .apply
          .feature
          .repository
          .state
          .softwareCards[card.softwareId]!
          .configPaths,
      card.configPaths,
    );
    expect(h.server.publications, greaterThan(0));
    final after = h.apply.feature.repository.state;
    final base = after.syncRoots[after.syncState.baseRootId]!;
    final manifest = h.server.head.manifest!;
    final root = h.apply.crypto.decryptRoot(
      envelope: Uint8List.fromList(base.manifestCiphertext),
      root: manifest.root,
      objects: manifest.objects,
      snapshotId: manifest.snapshotId,
      revision: h.server.head.revision,
    );
    expect(
      root.entries.where((entry) => entry.kind == 'software').single.id,
      card.softwareId,
    );
  });
  test('normal foreground cycle publishes durable pending and schedules one idle poll', () async {
    await h.cycle.resume();
    await turns();
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.server.publications, 1);
    expect(h.apply.feature.repository.state.syncState.baseRevision, 2);
    expect(h.apply.feature.repository.state.syncState.pendingRootId, isNull);
    expect(h.cycle.view.pendingChanges, 0);
    expect(h.cycle.view.pendingBytes, isNull);
    expect(h.timerCount, 1);
    expect(h.nextDelay, const Duration(seconds: 60));
  });

  test('idle poll downloads authenticated remote additions and deletions then applies once', () async {
    await h.cycle.resume();
    await h.cloud([mergeProfile(10), mergeCard(11, 10)]);
    h.apply.feature.clock.advance(const Duration(seconds: 60));
    await turns();
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    final domain = h.apply.feature.repository.state;
    expect(domain.profiles.keys, [mergeId(10)]);
    expect(domain.softwareCards.keys, [mergeId(11)]);
    expect(domain.softwareEvents, isEmpty);
    expect(domain.profiles[mergeId(10)]!.syncAutoBlocked, isTrue);
    expect(domain.syncState.baseRevision, 3);
    expect(h.server.downloads.length, 3);
    expect(h.server.downloadedBuffers.expand((b) => b), everyElement(0));
    expect(h.server.publications, 1);
    expect(h.timerCount, 1);
  });

  test('first empty cloud requires explicit composition consent before declaration', () async {
    h.freshCloud();
    await h.cycle.resume();
    expect(h.cycle.view.phase, SyncCyclePhase.consent);
    expect(h.server.publications, 0);
    expect(h.server.leases, isEmpty);
    await h.cycle.confirm(h.cycle.view.preview!, SyncMergeChoice.automatic);
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.server.publications, 1);
    expect(h.apply.feature.repository.state.profiles.keys, [h.localId]);
  });

  test('three-way disjoint offline changes merge, apply remote and publish complete target', () async {
    await h.cycle.resume();
    final changed = await h.apply.feature.profiles.updateProfile(
      h.apply.feature.actors.ui,
      h.localId,
      const ProfilePatch(displayName: 'local renamed'),
      expectedRevision: 1,
      mutationId: 'offline',
    );
    expect(changed.ok, isTrue);
    // Cloud keeps the original local object by decrypting its published cache.
    final base = h
        .apply
        .feature
        .repository
        .state
        .syncRoots[h.apply.feature.repository.state.syncState.baseRootId]!;
    final manifest = h.server.head.manifest!;
    final root = h.apply.crypto.decryptRoot(
      envelope: Uint8List.fromList(base.manifestCiphertext),
      root: manifest.root,
      objects: manifest.objects,
      snapshotId: manifest.snapshotId,
      revision: manifest.revision,
    );
    final entry = root.entries.single;
    final content = h.apply.crypto.decryptContent(
      envelope: Uint8List.fromList(
        h.apply.repository.readObject(h.apply.fence, entry.sha256).cipherBytes,
      ),
      expected: entry,
    );
    await h.cloud([content, mergeProfile(10)]);
    await h.cycle.retry();
    await turns();
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.apply.feature.repository.state.profiles.length, 2);
    expect(
      h.apply.feature.repository.state.profiles[h.localId]!.displayName,
      'local renamed',
    );
    expect(h.apply.feature.repository.state.syncState.baseRevision, 4);
    expect(h.server.publications, 2);
  });

  test(
    'edit/edit conflict publishes nothing until whole-set server choice',
    () async {
      await h.cycle.resume();
      final changed = await h.apply.feature.profiles.updateProfile(
        h.apply.feature.actors.ui,
        h.localId,
        const ProfilePatch(displayName: 'local choice'),
        expectedRevision: 1,
        mutationId: 'conflict-local',
      );
      expect(changed.ok, isTrue);
      await h.cloud([h.apply.stored(h.localId, name: 'remote choice')]);
      await h.cycle.retry();
      expect(h.cycle.view.phase, SyncCyclePhase.conflict);
      expect(h.server.publications, 1);
      await h.cycle.confirm(h.cycle.view.preview!, SyncMergeChoice.server);
      expect(h.cycle.view.phase, SyncCyclePhase.synced);
      expect(
        h.apply.feature.repository.state.profiles[h.localId]!.displayName,
        'remote choice',
      );
      expect(h.server.publications, 1);
    },
  );

  test('retryable network failure has one 5 then 10 second timer and manual retry coalesces', () async {
    final pending = h.pending;
    final expectedBytes = pending.objectLengths.fold<int>(
      pending.manifestLength,
      (sum, n) => sum + n,
    );
    h.server.beforeHead = () async =>
        throw const OperationFailure(FailureCode.networkError, retryable: true);
    await h.cycle.resume();
    expect(h.cycle.view.phase, SyncCyclePhase.offlinePending);
    expect(h.cycle.view.pendingBytes, expectedBytes);
    expect(h.nextDelay, const Duration(seconds: 5));
    final count = h.server.calls.length;
    await h.cycle.retry();
    await h.cycle.retry();
    expect(h.server.calls.length, count);
    expect(h.timerCount, 1);
    h.apply.feature.clock.advance(const Duration(seconds: 5));
    await turns();
    expect(h.nextDelay, const Duration(seconds: 10));
    h.server.beforeHead = null;
    h.apply.feature.clock.advance(const Duration(seconds: 10));
    await turns();
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.timerCount, 1);
  });

  test(
    'pause during download cancels late body and suppresses writes and timers',
    () async {
      await h.cycle.resume();
      await h.cloud([mergeProfile(10)]);
      final entered = Completer<void>(), release = Completer<void>();
      h.server.beforeRead = (_, _) async {
        entered.complete();
        await release.future;
      };
      final active = h.cycle.retry();
      await entered.future;
      final previous = h.apply.feature.repository.state.syncState.baseRevision;
      h.cycle.pause();
      expect(h.timerCount, 0);
      release.complete();
      await active;
      expect(h.cycle.view.phase, SyncCyclePhase.paused);
      expect(h.apply.feature.repository.state.syncState.baseRevision, previous);
      expect(h.apply.feature.repository.state.profiles.keys, [h.localId]);
      h.server.beforeRead = null;
      await h.cycle.resume();
      expect(h.cycle.view.phase, SyncCyclePhase.synced);
      expect(h.apply.feature.repository.state.profiles.keys, [mergeId(10)]);
    },
  );
  test('Retry-After above backoff is respected by explicit retry and chunked timers', () async {
    h.server.beforeHead = () async => throw SyncRemoteFailure.parse(429, {
      'error': 'rate_limited',
      'request_id': featureId(990010),
      'retry_after_seconds': 9007199254740991,
    }, '9007199254740991');
    await h.cycle.resume();
    expect(h.cycle.view.retryAfterSeconds, 9007199254740991);
    expect(h.nextDelay, const Duration(seconds: 300));
    final calls = h.server.calls.length;
    h.apply.feature.clock.advance(const Duration(seconds: 300));
    await turns();
    await h.cycle.retry();
    expect(h.server.calls.length, calls);
    expect(h.timerCount, 1);
    expect(h.nextDelay, const Duration(seconds: 300));
    h.cycle.pause();
    await h.cycle.resume();
    expect(h.server.calls.length, calls);
    expect(h.timerCount, 1);
  });

  test(
    'backoff doubles to 300 seconds and stays bounded with one timer',
    () async {
      h.server.beforeHead = () async => throw const OperationFailure(
        FailureCode.networkError,
        retryable: true,
      );
      await h.cycle.resume();
      for (final seconds in [5, 10, 20, 40, 80, 160, 300, 300]) {
        expect(h.nextDelay, Duration(seconds: seconds));
        expect(h.timerCount, 1);
        h.apply.feature.clock.advance(Duration(seconds: seconds));
        await turns();
      }
      expect(h.nextDelay, const Duration(seconds: 300));
    },
  );

  test('revision change during download retains domain and reconciles latest head after bounded wait', () async {
    await h.cycle.resume();
    await h.cloud([mergeProfile(10)]);
    var changed = false;
    h.server.beforeRead = (_, _) async {
      if (!changed) {
        changed = true;
        await h.cloud([mergeProfile(20)]);
      }
    };
    await h.cycle.retry();
    expect(h.cycle.view.errorCode, 'revision_changed');
    expect(h.nextDelay, const Duration(seconds: 5));
    expect(h.apply.feature.repository.state.syncState.baseRevision, 2);
    expect(h.apply.feature.repository.state.profiles.keys, [h.localId]);
    h.apply.feature.clock.advance(const Duration(seconds: 5));
    await turns();
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.apply.feature.repository.state.syncState.baseRevision, 4);
    expect(h.apply.feature.repository.state.profiles.keys, [mergeId(20)]);
  });

  test(
    'tampered root is refused before candidate admission or domain effects',
    () async {
      await h.cycle.resume();
      final manifest = await h.cloud([mergeProfile(10)]);
      h.server.blobs[manifest.root.sha256]![0] ^= 1;
      await h.cycle.retry();
      expect(h.cycle.view.phase, SyncCyclePhase.error);
      expect(
        h.apply.feature.repository.state.syncState.candidateRootId,
        isNull,
      );
      expect(h.apply.feature.repository.state.syncState.baseRevision, 2);
      expect(h.apply.feature.repository.state.profiles.keys, [h.localId]);
      expect(h.timerCount, 0);
      expect(h.server.downloadedBuffers.expand((b) => b), everyElement(0));
    },
  );

  test(
    'tampered data object retains previous base and local credentials',
    () async {
      await h.cycle.resume();
      final manifest = await h.cloud([mergeProfile(10)]);
      h.server.blobs[manifest.objects.single.sha256]![0] ^= 1;
      final before = h
          .apply
          .feature
          .repository
          .state
          .credentials
          .values
          .single
          .protectedBytes
          .toList();
      await h.cycle.retry();
      expect(h.cycle.view.phase, SyncCyclePhase.error);
      expect(h.apply.feature.repository.state.syncState.baseRevision, 2);
      expect(
        h
            .apply
            .feature
            .repository
            .state
            .credentials
            .values
            .single
            .protectedBytes,
        before,
      );
      expect(h.apply.feature.repository.state.profiles.keys, [h.localId]);
      expect(h.server.downloadedBuffers.expand((b) => b), everyElement(0));
    },
  );

  test('missing retained base requires explicit fresh composition instead of blind publication', () async {
    await h.cycle.resume();
    final domain = h.apply.feature.repository.state;
    domain.syncRoots.remove(domain.syncState.baseRootId);
    await h.cloud([mergeProfile(10)]);
    await h.cycle.retry();
    expect(h.cycle.view.phase, SyncCyclePhase.consent);
    expect(h.cycle.view.preview!.baseUnavailable, isTrue);
    expect(h.server.publications, 1);
    expect(domain.profiles.keys, [h.localId]);
    await h.cycle.confirm(h.cycle.view.preview!, SyncMergeChoice.server);
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.apply.feature.repository.state.profiles.keys, [mergeId(10)]);
  });

  test(
    'local edit during older upload is exported by a later immutable intent',
    () async {
      var edited = false;
      h.server.afterUpload = (_, _) async {
        if (!edited) {
          edited = true;
          final result = await h.apply.feature.profiles.updateProfile(
            h.apply.feature.actors.ui,
            h.localId,
            const ProfilePatch(displayName: 'during upload'),
            expectedRevision: 1,
            mutationId: 'during-upload',
          );
          expect(result.ok, isTrue);
        }
      };
      await h.cycle.resume();
      await turns();
      expect(h.cycle.view.phase, SyncCyclePhase.synced);
      final domain = h.apply.feature.repository.state;
      expect(domain.syncState.ackGeneration, domain.syncState.syncGeneration);
      expect(domain.syncState.baseRevision, 3);
      expect(domain.profiles[h.localId]!.displayName, 'during upload');
      expect(h.server.publications, 2);
    },
  );

  test('lost commit response recovers receipt before applying a subsequently advanced head', () async {
    h.server.loseResponses = 1;
    await h.cycle.resume();
    expect(h.cycle.view.phase, SyncCyclePhase.offlinePending);
    expect(h.apply.feature.repository.state.syncState.pendingRootId, isNotNull);
    await h.cloud([mergeProfile(10)]);
    h.apply.feature.clock.advance(const Duration(seconds: 5));
    await turns();
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.apply.feature.repository.state.syncState.baseRevision, 3);
    expect(h.apply.feature.repository.state.profiles.keys, [mergeId(10)]);
    expect(h.server.publications, 1);
  });

  test('local edit invalidates consent before any declaration', () async {
    h.freshCloud();
    await h.cycle.resume();
    final preview = h.cycle.view.preview!;
    final result = await h.apply.feature.profiles.updateProfile(
      h.apply.feature.actors.ui,
      h.localId,
      const ProfilePatch(displayName: 'after preview'),
      expectedRevision: 1,
      mutationId: 'after-preview',
    );
    expect(result.ok, isTrue);
    await turns();
    await expectLater(
      h.cycle.confirm(preview, SyncMergeChoice.automatic),
      throwsA(featureFailure(FailureCode.conflict)),
    );
    expect(h.server.publications, 0);
    expect(h.server.leases, isEmpty);
  });

  test('retiring intent demands fresh explicit choice and is never revived by idle poll', () async {
    h.apply.feature.repository.state.syncState.pendingUploadRetiring = true;
    await h.cycle.resume();
    expect(h.cycle.view.phase, SyncCyclePhase.consent);
    expect(h.server.publications, 0);
    h.cycle.cancelPreview();
    h.apply.feature.clock.advance(const Duration(seconds: 60));
    await turns();
    expect(h.cycle.view.phase, SyncCyclePhase.consent);
    expect(h.server.publications, 0);
    await h.cycle.confirm(h.cycle.view.preview!, SyncMergeChoice.automatic);
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.server.publications, 1);
    expect(
      h.apply.feature.repository.state.syncState.pendingUploadRetiring,
      isFalse,
    );
  });

  test('key loss during native protection denies late cache/apply and schedules nothing', () async {
    await h.cycle.resume();
    await h.cloud([mergeProfile(10)]);
    h.apply.secrets.hold = Completer<void>();
    final oldProtects = h.apply.secrets.protects;
    final active = h.cycle.retry();
    await turns();
    expect(h.apply.secrets.protects, greaterThan(oldProtects));
    h.keyReady = false;
    h.apply.secrets.hold!.complete();
    await active;
    expect(h.cycle.view.phase, SyncCyclePhase.waitingForKey);
    expect(h.timerCount, 0);
    expect(h.apply.feature.repository.state.syncState.baseRevision, 2);
    expect(h.apply.feature.repository.state.profiles.keys, [h.localId]);
    expect(h.apply.secrets.inputs.last, everyElement(0));
  });

  test('concurrent explicit retries share a single native cycle', () async {
    await h.cycle.resume();
    await h.cloud([mergeProfile(10)]);
    final entered = Completer<void>(), release = Completer<void>();
    h.server.beforeRead = (_, _) async {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    final first = h.cycle.retry();
    await entered.future;
    expect(identical(h.cycle.retry(), first), isTrue);
    expect(h.timerCount, 0);
    release.complete();
    await first;
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.server.downloads.length, 2);
    expect(h.timerCount, 1);
  });
  test('CAS head advance retires the old live upload before publishing merged target', () async {
    var moved = false;
    h.server.beforeCommit = (_) async {
      if (!moved && h.server.leases.isNotEmpty) {
        moved = true;
        await h.cloud([mergeProfile(10)], revision: 2);
      }
    };
    final old = h.apply.feature.repository.state.syncState.pendingUploadId;
    await h.cycle.resume();
    await turns();
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.server.cancels, [old]);
    expect(h.server.leases[old]!.expired, isTrue);
    expect(h.server.leases.length, 2);
    expect(h.server.publications, 1);
    expect(h.apply.feature.repository.state.profiles.length, 2);
    expect(h.apply.feature.repository.state.syncState.baseRevision, 3);
  });

  test('uncertain cancellation in automatic merge requires explicit fresh recovery choice', () async {
    var moved = false;
    h.server.beforeCommit = (_) async {
      if (!moved && h.server.leases.isNotEmpty) {
        moved = true;
        await h.cloud([mergeProfile(10)], revision: 2);
      }
    };
    h.server.afterCancel = (_) async =>
        throw const OperationFailure(FailureCode.networkError, retryable: true);
    await h.cycle.resume();
    expect(h.cycle.view.phase, SyncCyclePhase.offlinePending);
    expect(
      h.apply.feature.repository.state.syncState.pendingUploadRetiring,
      isTrue,
    );
    expect(h.server.publications, 0);
    h.server.afterCancel = null;
    h.apply.feature.clock.advance(const Duration(seconds: 5));
    await turns();
    expect(h.cycle.view.phase, SyncCyclePhase.consent);
    expect(h.server.publications, 0);
    await h.cycle.confirm(h.cycle.view.preview!, SyncMergeChoice.automatic);
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.server.cancels.length, 2);
    expect(h.server.publications, 1);
    expect(h.apply.feature.repository.state.profiles.length, 2);
  });

  test('paused and locked cycles send no requests or timers until explicitly resumed ready', () async {
    h.keyReady = false;
    final calls = h.server.calls.length;
    await h.cycle.resume();
    expect(h.cycle.view.phase, SyncCyclePhase.waitingForKey);
    expect(h.server.calls.length, calls);
    expect(h.timerCount, 0);
    h.cycle.pause();
    await expectLater(h.cycle.retry(), throwsA(isA<SyncTransportCancelled>()));
    expect(h.server.calls.length, calls);
    h.keyReady = true;
    await h.cycle.resume();
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.timerCount, 1);
  });

  test('missing cached base object is reconstructed from current authenticated head', () async {
    await h.cycle.resume();
    final domain = h.apply.feature.repository.state;
    final base = domain.syncRoots[domain.syncState.baseRootId]!;
    final key = h.apply.fence.identity.objectKey(base.objectHashes.single);
    domain.syncObjects[key]!
      ..cipherBytes = []
      ..cipherLength = 0;
    await h.cycle.retry();
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(h.server.downloads, [base.objectHashes.single]);
    expect(h.server.publications, 1);
    expect(h.apply.feature.repository.state.syncState.baseRevision, 2);
  });
  test('auth owner configures exactly one same-repository cycle and owns its stop boundary', () async {
    final owner = SyncOwner(
      repository: h.apply.repository,
      secrets: h.apply.secrets,
      browser: auth.Browser(),
      transport: (origin) => SyncTransport(
        origin: origin,
        http: wire.FakeHttp(
          (_, _) async => throw StateError('no auth HTTP expected'),
        ),
      ),
    );
    final transfer = SyncCredentialTransfer(
      repository: h.apply.feature.repository,
      secrets: h.apply.secrets,
      inspector: Inspector(),
      access: owner,
    );
    final apply = SyncApply(
      repository: h.apply.repository,
      transfer: transfer,
      gate: h.apply.feature.gate,
      actor: h.apply.feature.actors.owner,
      connections: h.apply.batches,
      newId: h.apply.feature.newId,
      utcNow: h.apply.feature.clock.now,
    );
    final cycle = owner.configureCycle(
      transfer: transfer,
      apply: apply,
      newId: h.apply.feature.newId,
      utcNow: h.apply.feature.clock.now,
      schedule: h.apply.feature.clock.schedule,
    );
    expect(identical(owner.cycle, cycle), isTrue);
    expect(cycle.view.phase, SyncCyclePhase.paused);
    expect(
      () => owner.configureCycle(
        transfer: transfer,
        apply: apply,
        newId: h.apply.feature.newId,
        utcNow: h.apply.feature.clock.now,
      ),
      throwsA(featureFailure(FailureCode.conflict)),
    );
    await cycle.resume();
    expect(cycle.view.phase, SyncCyclePhase.waitingForKey);
    owner.pause();
    expect(cycle.view.phase, SyncCyclePhase.paused);
    expect(h.timerCount, 0);
    await cycle.dispose();
    owner.dispose();
  });

  test(
    'unsupported content requires update with no retry, reset or domain loss',
    () async {
      h.server.beforeHead = () async =>
          throw const SyncUnsupportedContentVersion();
      await h.cycle.resume();
      expect(h.cycle.view.phase, SyncCyclePhase.error);
      expect(h.cycle.view.errorCode, 'CONTENT_UPDATE_REQUIRED');
      expect(h.timerCount, 0);
      expect(h.apply.feature.repository.state.profiles.keys, [h.localId]);
      expect(
        h.apply.feature.repository.state.syncState.pendingRootId,
        isNotNull,
      );
    },
  );
}
