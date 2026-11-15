import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_publication.dart';
import 'package:serverdeck/sync/sync_transport.dart';

import '../fixtures/feature_harness.dart';
import '../fixtures/sync_publication.dart';

void main() {
  late PublicationHarness h;
  setUp(() async {
    h = PublicationHarness();
    await h.setup();
  });
  tearDown(() => h.dispose());

  test(
    'durable lease precedes HTTP, publishes once and wipes owned PUT bodies',
    () async {
      final state = h.apply.feature.repository.state.syncState;
      final root = state.pendingRootId!, commit = state.pendingCommitId!;
      final generation = state.syncGeneration;
      expect(state.pendingUploadId, root);
      expect(
        state.pendingUploadDeviceId,
        h.server.context.fence.identity.deviceId,
      );
      final result = await h.publish();
      expect(result.disposition, SyncPublicationDisposition.acknowledged);
      expect(h.server.publications, 1);
      expect(h.server.commits, everyElement((root, commit)));
      expect(h.server.calls.first, 'commit:$root');
      expect(h.server.received, isNotEmpty);
      for (final bytes in h.server.received) {
        expect(bytes, everyElement(0));
      }
      final after = h.apply.feature.repository.state.syncState;
      expect(after.pendingRootId, isNull);
      expect(after.pendingCommitId, isNull);
      expect(after.pendingUploadId, isNull);
      expect(after.pendingUploadDeviceId, isNull);
      expect(after.baseRootId, root);
      expect(after.baseRevision, 2);
      expect(after.ackGeneration, generation);
      expect(after.syncGeneration, generation);
    },
  );

  test('lost commit response replays receipt before advanced head and preserves newer edits', () async {
    final pending = h.pending.rootId;
    final source = h.pending.sourceGeneration;
    h.server.loseResponses = 1;
    await expectLater(
      h.publish(),
      throwsA(featureFailure(FailureCode.networkError)),
    );
    expect(h.apply.feature.repository.state.syncState.pendingRootId, pending);
    h.server.advanceHead();
    final rename = await h.apply.feature.profiles.updateProfile(
      h.apply.feature.actors.ui,
      h.localId,
      const ProfilePatch(displayName: 'newer local'),
      expectedRevision: 1,
      mutationId: 'newer-publication',
    );
    expect(rename.ok, isTrue);
    h.server.calls.clear();
    final result = await h.publish(owner: h.makePublisher());
    expect(result.disposition, SyncPublicationDisposition.acknowledged);
    expect(h.server.calls, ['commit:$pending']);
    expect(h.server.publications, 1);
    final domain = h.apply.feature.repository.state;
    expect(domain.syncState.ackGeneration, source);
    expect(domain.syncState.syncGeneration, source + 1);
    expect(domain.profiles[h.localId]!.displayName, 'newer local');
  });

  test('interrupted PUT resumes same lease and immutable bodies', () async {
    final cancel = SyncCancellation();
    final upload = h.apply.feature.repository.state.syncState.pendingUploadId!;
    h.server.afterUpload = (_, _) async => cancel.cancel();
    await expectLater(
      h.publish(cancel: cancel),
      throwsA(isA<SyncTransportCancelled>()),
    );
    final first = h.server.sent.single;
    h.server.afterUpload = null;
    await h.publish(owner: h.makePublisher());
    expect(h.server.publications, 1);
    expect(h.server.leases.keys, [upload]);
    final repeated = h.server.sent.where((row) => row.$2 == first.$2).toList();
    expect(repeated.length, 2);
    expect(repeated.last.$3, first.$3);
    expect(h.server.received.expand((b) => b), everyElement(0));
  });

  test('expired upload renews only after fresh base proof, keeping commit and snapshot', () async {
    final state = h.apply.feature.repository.state.syncState;
    final upload = state.pendingUploadId!, commit = state.pendingCommitId!;
    final manifest = syncManifestForRoot(h.pending);
    h.server.leases[upload] = PublicationLease(
      h.server.context.fence.identity.deviceId,
      manifest,
      [],
    )..expired = true;
    await h.publish();
    expect(h.server.calls[0], 'commit:$upload');
    expect(h.server.calls[1], 'head');
    final renewed = h.server.leases.entries
        .where((e) => e.key != upload)
        .single;
    expect(sameSyncManifest(renewed.value.manifest, manifest), isTrue);
    expect(h.server.commits.last, (renewed.key, commit));
    expect(h.server.publications, 1);
  });

  test(
    'changed head with expired lease preserves pending for reconciliation',
    () async {
      final state = h.apply.feature.repository.state.syncState;
      final upload = state.pendingUploadId!;
      h.server.leases[upload] = PublicationLease(
        h.server.context.fence.identity.deviceId,
        syncManifestForRoot(h.pending),
        [],
      )..expired = true;
      h.server.advanceHead();
      final result = await h.publish();
      expect(result.disposition, SyncPublicationDisposition.reconcile);
      expect(h.server.leases.length, 1);
      expect(h.server.publications, 0);
      expect(
        h.apply.feature.repository.state.syncState.pendingUploadId,
        upload,
      );
      expect(h.apply.feature.repository.state.syncState.baseRevision, 1);
    },
  );

  test(
    'foreign-device lease is never probed and is replaced after fresh head',
    () async {
      final state = h.apply.feature.repository.state.syncState;
      final old = state.pendingUploadId!;
      state.pendingUploadDeviceId = featureId(990002);
      h.server.leases[old] = PublicationLease(
        state.pendingUploadDeviceId!,
        syncManifestForRoot(h.pending),
        [],
      );
      await h.publish();
      expect(h.server.calls.first, 'head');
      expect(h.server.commits.any((r) => r.$1 == old), isFalse);
      expect(h.server.publications, 1);
    },
  );

  test(
    'legacy absent lease is persisted only after fresh base proof',
    () async {
      final state = h.apply.feature.repository.state.syncState;
      final root = state.pendingRootId!;
      state.pendingUploadId = null;
      state.pendingUploadDeviceId = null;
      await h.publish();
      expect(h.server.calls.first, 'head');
      expect(h.server.leases.keys, [root]);
      expect(h.server.publications, 1);
    },
  );

  test(
    'missing retained base cannot authorize publication over positive head',
    () async {
      final domain = h.apply.feature.repository.state;
      domain.syncRoots.remove(domain.syncState.baseRootId);
      final result = await h.publish();
      expect(result.disposition, SyncPublicationDisposition.reconcile);
      expect(h.server.leases, isEmpty);
      expect(domain.syncState.pendingRootId, isNotNull);
    },
  );

  test('native epoch invalidated inside ACK write retains intent for receipt recovery', () async {
    final root = h.pending.rootId;
    h.apply.feature.repository.beforeWrite = () async {
      h.server.current = false;
    };
    await expectLater(h.publish(), throwsA(isA<OperationFailure>()));
    expect(h.server.publications, 1);
    expect(h.apply.feature.repository.state.syncState.pendingRootId, root);
    h.apply.feature.repository.beforeWrite = null;
    h.server.current = true;
    await h.publish(owner: h.makePublisher());
    expect(h.server.publications, 1);
    expect(h.apply.feature.repository.state.syncState.pendingRootId, isNull);
  });

  test('corrupt persisted ciphertext is refused before HTTP', () async {
    h.pending.manifestCiphertext[0] ^= 1;
    await expectLater(h.publish(), throwsA(anything));
    expect(h.server.calls, isEmpty);
    expect(h.apply.feature.repository.state.syncState.pendingRootId, isNotNull);
  });

  test('single flight denies concurrent publisher work and cancellation releases it', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final cancel = SyncCancellation();
    h.server.afterUpload = (_, _) async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    };
    final first = h.publish(cancel: cancel);
    final refusal = expectLater(first, throwsA(isA<SyncTransportCancelled>()));
    await entered.future;
    await expectLater(
      h.publish(),
      throwsA(featureFailure(FailureCode.resourceExhausted)),
    );
    cancel.cancel();
    release.complete();
    await refusal;
    h.server.afterUpload = null;
    await h.publish();
    expect(h.server.publications, 1);
  });
  test(
    'head CAS race before final commit returns reconciliation without ACK',
    () async {
      final root = h.pending.rootId;
      h.server.beforeCommit = (_) async {
        if (h.server.leases.isNotEmpty) h.server.advanceHead();
      };
      final result = await h.publish();
      expect(result.disposition, SyncPublicationDisposition.reconcile);
      expect(h.server.publications, 0);
      expect(h.apply.feature.repository.state.syncState.pendingRootId, root);
    },
  );

  test('missing receipt with exact published head safely acknowledges frozen proof', () async {
    h.server.loseResponses = 1;
    await expectLater(
      h.publish(),
      throwsA(featureFailure(FailureCode.networkError)),
    );
    h.server.leases.clear();
    h.server.calls.clear();
    final result = await h.publish(owner: h.makePublisher());
    expect(result.disposition, SyncPublicationDisposition.acknowledged);
    expect(h.server.calls.length, 2);
    expect(h.server.calls.last, 'head');
    expect(h.server.publications, 1);
  });

  test(
    'lease expiration during PUT renews once using the same frozen intent',
    () async {
      final root = h.pending.rootId;
      var expired = false;
      h.server.afterUpload = (upload, _) async {
        if (!expired) {
          expired = true;
          h.server.leases[upload]!.expired = true;
        }
      };
      final result = await h.publish();
      expect(result.disposition, SyncPublicationDisposition.acknowledged);
      expect(h.server.leases.length, 2);
      expect(h.server.publications, 1);
      expect(h.apply.feature.repository.state.syncState.baseRootId, root);
    },
  );

  test(
    'renewal invalidated inside queued write cannot replace durable lease',
    () async {
      final state = h.apply.feature.repository.state.syncState;
      final upload = state.pendingUploadId!;
      h.server.leases[upload] = PublicationLease(
        h.server.context.fence.identity.deviceId,
        syncManifestForRoot(h.pending),
        [],
      )..expired = true;
      h.apply.feature.repository.beforeWrite = () async =>
          h.server.current = false;
      await expectLater(h.publish(), throwsA(isA<OperationFailure>()));
      expect(
        h.apply.feature.repository.state.syncState.pendingUploadId,
        upload,
      );
      expect(h.server.leases.length, 1);
      expect(h.server.calls.where((c) => c.startsWith('declare:')), isEmpty);
    },
  );
}
