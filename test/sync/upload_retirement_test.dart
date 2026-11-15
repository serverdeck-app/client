import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_merge.dart';
import 'package:serverdeck/sync/sync_publication.dart';
import 'package:serverdeck/sync/sync_retirement.dart';
import 'package:serverdeck/sync/sync_transport.dart';
import 'package:serverdeck/sync/sync_wire.dart';

import '../fixtures/feature_harness.dart';
import '../fixtures/sync_apply.dart';
import '../fixtures/sync_publication.dart';

void main() {
  late PublicationHarness h;
  late SyncUploadRetirement retirement;
  SyncUploadRetirement makeRetirement({SyncPendingPublisher? publisher}) =>
      SyncUploadRetirement(
        repository: h.apply.repository,
        access: h.server,
        publisher: publisher ?? h.publisher,
        utcNow: h.apply.feature.clock.now,
      );
  setUp(() async {
    h = PublicationHarness();
    await h.setup();
    retirement = makeRetirement();
  });
  tearDown(() => h.dispose());

  Future<ApplyRemote> remote() async {
    final value = await h.apply.remote([], revision: 2);
    h.server.head = h.apply.access.head;
    return value;
  }

  Future<T> choose<T>(
    ApplyRemote value,
    Future<T> Function(SyncMergeAuthorization) run, {
    SyncMergeChoice choice = SyncMergeChoice.server,
  }) async {
    final preview = await h.apply.merge.propose(
      local: await h.apply.local(),
      remote: value.snapshot,
    );
    return h.apply.merge.confirm(preview, choice, run);
  }

  void lease({String? id}) {
    final state = h.apply.feature.repository.state.syncState;
    h.server.leases[id ?? state.pendingUploadId!] = PublicationLease(
      state.pendingUploadDeviceId!,
      syncManifestForRoot(h.pending),
      [syncManifestForRoot(h.pending).root.sha256],
    );
  }

  Future<SyncRetirementResult> retire(ApplyRemote value) => choose(
    value,
    (authority) => retirement.retire(authority, h.apply.crypto),
  );

  test(
    'rotated partial lease closes before replacement and new publication',
    () async {
      final state = h.apply.feature.repository.state.syncState;
      final oldRoot = state.pendingRootId!, oldCommit = state.pendingCommitId!;
      final upload = featureId(990003);
      await h.apply.repository.replacePendingUpload(
        h.apply.fence,
        rootId: oldRoot,
        commitId: oldCommit,
        expectedUploadId: state.pendingUploadId,
        expectedUploadDeviceId: state.pendingUploadDeviceId,
        uploadId: upload,
        isCurrent: () => true,
      );
      lease();
      h.server.beforeCancel = (_) async {
        expect(
          h.apply.feature.repository.state.syncState.pendingUploadRetiring,
          isTrue,
        );
        expect(
          h.apply.feature.repository.state.syncState.pendingUploadId,
          upload,
        );
        await expectLater(
          h.publish(),
          throwsA(featureFailure(FailureCode.resourceExhausted)),
        );
      };
      final value = await remote();
      await choose(value, (authority) async {
        final retired = await retirement.retire(authority, h.apply.crypto);
        expect(retired.rebuild, isFalse);
        await h.apply.apply.apply(
          authority,
          h.apply.crypto,
          remoteRootId: value.rootId,
          retiredUpload: retired.closed,
        );
      }, choice: SyncMergeChoice.local);
      final after = h.apply.feature.repository.state.syncState;
      expect(h.server.cancels, [upload]);
      expect(h.server.leases[upload]!.expired, isTrue);
      expect(after.pendingRootId, isNot(oldRoot));
      expect(after.pendingCommitId, isNot(oldCommit));
      expect(after.pendingUploadRetiring, isFalse);
      await h.publish();
      expect(h.server.publications, 1);
      expect(h.server.leases.length, 2);
    },
  );

  test('server choice clears old pending only with closure token', () async {
    lease();
    final value = await remote();
    await choose(value, (authority) async {
      final result = await retirement.retire(authority, h.apply.crypto);
      await h.apply.apply.apply(
        authority,
        h.apply.crypto,
        remoteRootId: value.rootId,
        retiredUpload: result.closed,
      );
    });
    final domain = h.apply.feature.repository.state;
    expect(domain.syncState.pendingRootId, isNull);
    expect(domain.syncState.pendingUploadRetiring, isFalse);
    expect(domain.profiles, isEmpty);
    expect(domain.syncState.baseRootId, value.rootId);
  });

  test(
    'apply cannot bypass cancellation before irreversible connection cleanup',
    () async {
      final session = await h.apply.connected(h.localId);
      final root = h.pending.rootId;
      final value = await remote();
      await expectLater(
        choose(
          value,
          (authority) => h.apply.apply.apply(
            authority,
            h.apply.crypto,
            remoteRootId: value.rootId,
          ),
        ),
        throwsA(featureFailure(FailureCode.conflict)),
      );
      expect(session.closeCalls, 0);
      expect(h.apply.feature.repository.state.syncState.pendingRootId, root);
      expect(h.server.cancels, isEmpty);
    },
  );

  test('lost cancel response preserves durable retirement and same ID after owner reconstruction', () async {
    lease();
    final value = await remote();
    final upload = h.apply.feature.repository.state.syncState.pendingUploadId;
    h.server.afterCancel = (_) async =>
        throw const OperationFailure(FailureCode.networkError, retryable: true);
    await expectLater(
      retire(value),
      throwsA(featureFailure(FailureCode.networkError)),
    );
    final state = h.apply.feature.repository.state.syncState;
    expect(state.pendingUploadRetiring, isTrue);
    expect(state.pendingUploadId, upload);
    expect(state.pendingRootId, isNotNull);
    await expectLater(
      h.publish(owner: h.makePublisher()),
      throwsA(featureFailure(FailureCode.conflict)),
    );
    h.server.afterCancel = null;
    retirement = makeRetirement(publisher: h.makePublisher());
    await choose(value, (authority) async {
      final result = await retirement.retire(authority, h.apply.crypto);
      await h.apply.apply.apply(
        authority,
        h.apply.crypto,
        remoteRootId: value.rootId,
        retiredUpload: result.closed,
      );
    });
    expect(h.server.cancels, [upload, upload]);
    expect(h.apply.feature.repository.state.syncState.pendingRootId, isNull);
  });

  test('crash-state reconstruction after successful DELETE cannot republish abandoned intent', () async {
    lease();
    final value = await remote();
    final first = await retire(value);
    expect(first.closed, isNotNull);
    expect(
      h.apply.feature.repository.state.syncState.pendingUploadRetiring,
      isTrue,
    );
    await expectLater(
      h.publish(owner: h.makePublisher()),
      throwsA(featureFailure(FailureCode.conflict)),
    );
    retirement = makeRetirement(publisher: h.makePublisher());
    final result = await retire(value);
    expect(result.closed, isNotNull);
    expect(h.server.cancels.length, 2);
    expect(h.server.publications, 0);
  });

  test('commit winning cancel race recovers receipt and preserves newer dirty generation', () async {
    h.server.loseResponses = 1;
    final source = h.pending.sourceGeneration;
    await expectLater(
      h.publish(),
      throwsA(featureFailure(FailureCode.networkError)),
    );
    final changed = await h.apply.feature.profiles.updateProfile(
      h.apply.feature.actors.ui,
      h.localId,
      const ProfilePatch(displayName: 'newer'),
      expectedRevision: 1,
      mutationId: 'after-publish',
    );
    expect(changed.ok, isTrue);
    final value = await h.apply.remote([], revision: 3);
    h.server.head = h.apply.access.head;
    final result = await retire(value);
    expect(result.rebuild, isTrue);
    expect(result.closed, isNull);
    final domain = h.apply.feature.repository.state;
    expect(domain.syncState.pendingRootId, isNull);
    expect(domain.syncState.baseRevision, 2);
    expect(domain.syncState.ackGeneration, source);
    expect(domain.syncState.syncGeneration, source + 1);
    expect(domain.profiles[h.localId]!.displayName, 'newer');
    expect(h.server.publications, 1);
  });

  test(
    'foreign-device and legacy null leases need no unauthorized DELETE',
    () async {
      for (final foreign in [true, false]) {
        final state = h.apply.feature.repository.state.syncState;
        if (foreign) {
          state.pendingUploadDeviceId = featureId(990004);
          lease();
        } else {
          state.pendingUploadId = null;
          state.pendingUploadDeviceId = null;
        }
        final value = await remote();
        final result = await retire(value);
        expect(result.closed, isNotNull);
        expect(h.server.cancels, isEmpty);
        expect(h.server.commits, isEmpty);
      }
    },
  );

  test(
    'local edit after DELETE leaves retiring intent and refuses stale apply',
    () async {
      lease();
      final value = await remote();
      h.server.afterCancel = (_) async {
        final changed = await h.apply.feature.profiles.updateProfile(
          h.apply.feature.actors.ui,
          h.localId,
          const ProfilePatch(displayName: 'late local'),
          expectedRevision: 1,
          mutationId: 'late-cancel',
        );
        expect(changed.ok, isTrue);
      };
      await expectLater(
        retire(value),
        throwsA(featureFailure(FailureCode.conflict)),
      );
      final domain = h.apply.feature.repository.state;
      expect(domain.syncState.pendingUploadRetiring, isTrue);
      expect(domain.syncState.pendingRootId, isNotNull);
      expect(domain.profiles[h.localId]!.displayName, 'late local');
    },
  );

  test('closure proof cannot escape the merge callback or be reused in new preview', () async {
    lease();
    final value = await remote();
    final first = await retire(value);
    await expectLater(
      choose(
        value,
        (authority) => h.apply.apply.apply(
          authority,
          h.apply.crypto,
          remoteRootId: value.rootId,
          retiredUpload: first.closed,
        ),
      ),
      throwsA(featureFailure(FailureCode.conflict)),
    );
    expect(h.apply.feature.repository.state.syncState.pendingRootId, isNotNull);
  });

  test('failed atomic apply retains retired pointer and domain for fresh reconciliation', () async {
    lease();
    final value = await remote();
    await expectLater(
      choose(value, (authority) async {
        final result = await retirement.retire(authority, h.apply.crypto);
        h.apply.batches.afterClose = () async {
          h.apply.feature.repository.failCommit = true;
        };
        await h.apply.apply.apply(
          authority,
          h.apply.crypto,
          remoteRootId: value.rootId,
          retiredUpload: result.closed,
        );
      }),
      throwsA(isA<OperationFailure>()),
    );
    final domain = h.apply.feature.repository.state;
    expect(domain.syncState.pendingUploadRetiring, isTrue);
    expect(domain.syncState.pendingRootId, isNotNull);
    expect(domain.profiles.keys, [h.localId]);
  });

  test('pause inside actual retirement write admits no cancellation', () async {
    lease();
    final value = await remote();
    h.apply.feature.repository.beforeWrite = () async =>
        h.server.current = false;
    await expectLater(retire(value), throwsA(isA<OperationFailure>()));
    expect(
      h.apply.feature.repository.state.syncState.pendingUploadRetiring,
      isFalse,
    );
    expect(h.server.cancels, isEmpty);
  });

  test(
    'retirement cancels and drains active PUT before marking and DELETE',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      h.server.afterUpload = (_, _) async {
        entered.complete();
        await release.future;
      };
      final publishing = h.publish();
      final stopped = expectLater(
        publishing,
        throwsA(isA<SyncTransportCancelled>()),
      );
      await entered.future;
      final value = await remote();
      final retiring = retire(value);
      await featureTurns();
      expect(h.server.cancels, isEmpty);
      expect(
        h.apply.feature.repository.state.syncState.pendingUploadRetiring,
        isFalse,
      );
      await expectLater(
        h.publish(),
        throwsA(featureFailure(FailureCode.resourceExhausted)),
      );
      release.complete();
      await stopped;
      final result = await retiring;
      expect(result.closed, isNotNull);
      expect(h.server.cancels.length, 1);
      expect(h.server.received.expand((b) => b), everyElement(0));
    },
  );
  test('committed receipt disappearing resolves only after repeated DELETE proves absence', () async {
    h.server.loseResponses = 1;
    await expectLater(
      h.publish(),
      throwsA(featureFailure(FailureCode.networkError)),
    );
    final value = await h.apply.remote([], revision: 3);
    h.server.head = h.apply.access.head;
    final upload = h.apply.feature.repository.state.syncState.pendingUploadId!;
    h.server.beforeCommit = (_) async {
      h.server.leases.remove(upload);
      throw h.server.error('not_found');
    };
    final result = await retire(value);
    expect(result.closed, isNotNull);
    expect(result.rebuild, isFalse);
    expect(h.server.cancels, [upload, upload]);
    expect(h.apply.feature.repository.state.syncState.pendingRootId, isNotNull);
    expect(
      h.apply.feature.repository.state.syncState.pendingUploadRetiring,
      isTrue,
    );
  });

  test('unavailable receipt with exact pending head is authenticated before ACK', () async {
    h.server.loseResponses = 1;
    await expectLater(
      h.publish(),
      throwsA(featureFailure(FailureCode.networkError)),
    );
    // Preview can be any valid current remote; the retirement's head proof must
    // still recognize committed pending and demand a new preview after ACK.
    final value = await h.apply.remote([], revision: 3);
    final committedHead = h.server.head;
    h.apply.access.head = SyncHead.parse({
      'vault_id': value.manifest.vaultId,
      'revision': 3,
      'manifest': value.manifest.toJson(),
    }, vaultId: value.manifest.vaultId);
    h.server.beforeCommit = (_) async => throw h.server.error('not_found');
    final result = await retire(value);
    expect(result.rebuild, isTrue);
    expect(h.server.head, committedHead);
    expect(h.apply.feature.repository.state.syncState.baseRevision, 2);
    expect(h.apply.feature.repository.state.syncState.pendingRootId, isNull);
  });

  test('unresolved committed lease never supplies closure merely from changed head', () async {
    h.server.loseResponses = 1;
    await expectLater(
      h.publish(),
      throwsA(featureFailure(FailureCode.networkError)),
    );
    final value = await h.apply.remote([], revision: 3);
    h.server.head = h.apply.access.head;
    h.server.beforeCommit = (_) async => throw h.server.error('not_found');
    await expectLater(retire(value), throwsA(isA<SyncRemoteFailure>()));
    expect(h.server.cancels.length, 2);
    expect(
      h.apply.feature.repository.state.syncState.pendingUploadRetiring,
      isTrue,
    );
    expect(h.apply.feature.repository.state.syncState.pendingRootId, isNotNull);
  });

  test('a retiring intent denies UUID renewal and invalidates an existing preparation', () async {
    final value = await remote();
    final state = h.apply.feature.repository.state.syncState;
    final scope = h.apply.repository.beginPreparation(
      h.apply.fence,
      expectedDataRevision:
          h.apply.feature.repository.state.settings.dataRevision,
      expectedSyncGeneration: state.syncGeneration,
      isCurrent: () => true,
    );
    addTearDown(scope.dispose);
    await retire(value);
    final after = h.apply.feature.repository.state.syncState;
    await expectLater(
      h.apply.repository.replacePendingUpload(
        h.apply.fence,
        rootId: after.pendingRootId!,
        commitId: after.pendingCommitId!,
        expectedUploadId: after.pendingUploadId,
        expectedUploadDeviceId: after.pendingUploadDeviceId,
        uploadId: featureId(990005),
        isCurrent: () => true,
      ),
      throwsA(featureFailure(FailureCode.conflict)),
    );
    await expectLater(
      h.apply.repository.prepareTransition(
        scope,
        remoteRootId: value.rootId,
        consumePending: true,
        acknowledgeGeneration: after.syncGeneration,
        successUtc: h.apply.feature.clock.now(),
      ),
      throwsA(featureFailure(FailureCode.conflict)),
    );
  });
}
