import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_merge.dart';
import 'package:serverdeck/sync/sync_transport.dart';

import '../fixtures/sync_merge.dart';

void main() {
  test('head replacement at same revision and edit during recheck invalidate choice', () async {
    for (final replaceHead in [true, false]) {
      final h = MergeHarness();
      await h.setup();
      addTearDown(h.controller.dispose);
      final preview = await h.controller.propose(
        local: h.local([mergeProfile(10)]),
        remote: h.remote([mergeProfile(20)]),
      );
      final gate = Completer<void>();
      h.access.gate = gate;
      var effects = 0;
      final run = h.controller.confirm(preview, SyncMergeChoice.automatic, (
        _,
      ) async {
        effects++;
      });
      if (replaceHead) {
        h.remote([mergeProfile(20, name: 'replacement')]);
      } else {
        h.root.domain.state.settings.dataRevision++;
      }
      gate.complete();
      await expectLater(run, throwsA(isA<OperationFailure>()));
      expect(effects, 0);
    }
  });

  test(
    'authorized write may advance counters; capability expires after callback',
    () async {
      final h = MergeHarness();
      await h.setup();
      addTearDown(h.controller.dispose);
      final preview = await h.controller.propose(
        local: h.local([]),
        remote: h.emptyRemote(),
      );
      SyncMergeAuthorization? held;
      await h.controller.confirm(preview, SyncMergeChoice.automatic, (
        grant,
      ) async {
        held = grant;
        grant.check();
        h.root.domain.state.settings.dataRevision++;
        h.root.domain.state.syncState.syncGeneration++;
      });
      expect(h.controller.view.phase, SyncMergePhase.idle);
      expect(held!.isCurrent(), isFalse);
    },
  );

  test('superseded head request cannot replace newer preview', () async {
    final h = MergeHarness();
    await h.setup();
    addTearDown(h.controller.dispose);
    final gate = Completer<void>();
    h.access.gate = gate;
    final old = h.controller.propose(
      local: h.local([mergeProfile(10)]),
      remote: h.emptyRemote(),
    );
    final failed = expectLater(old, throwsA(isA<SyncTransportCancelled>()));
    h.access.gate = null;
    final latest = await h.controller.propose(
      local: h.local([mergeProfile(10), mergeProfile(20)]),
      remote: h.emptyRemote(),
    );
    gate.complete();
    await failed;
    expect(identical(h.controller.view.preview, latest), isTrue);
    expect(latest.local.profiles, 2);
  });

  test(
    'empty cloud requires explicit consent even for an empty initial root',
    () async {
      final h = MergeHarness();
      await h.setup();
      addTearDown(h.controller.dispose);
      final local = h.local([]), remote = h.emptyRemote();
      final preview = await h.controller.propose(local: local, remote: remote);
      expect(preview.requiresConsent, isTrue);
      expect(preview.merged!.profiles, 0);
      var effects = 0;
      expect(effects, 0);
      final result = await h.controller.confirm(
        preview,
        SyncMergeChoice.automatic,
        (grant) async {
          grant.check();
          effects++;
          expect(grant.target.needsPublication, isTrue);
          expect(grant.target.needsLocalApply, isFalse);
          return 'frozen';
        },
      );
      expect(result, 'frozen');
      expect(effects, 1);
      expect(h.access.reads, 2);
    },
  );

  test(
    'first import unions different IDs despite identical host and names',
    () async {
      final h = MergeHarness();
      await h.setup();
      addTearDown(h.controller.dispose);
      final local = h.local([mergeProfile(10)]),
          remote = h.remote([mergeProfile(20), mergeCard(30, 20)]);
      final preview = await h.controller.propose(local: local, remote: remote);
      expect(preview.conflicts, isEmpty);
      expect(preview.merged!.profiles, 2);
      expect(preview.merged!.cards, 1);
      expect(preview.automaticChanges!.added.profiles, 1);
      await h.controller.confirm(preview, SyncMergeChoice.automatic, (
        grant,
      ) async {
        grant.check();
        expect(
          grant.target.records
              .where((r) => r.kind == 'profile')
              .map((r) => r.id),
          [mergeId(10), mergeId(20)],
        );
        expect(grant.target.needsPublication, isTrue);
        expect(grant.target.needsLocalApply, isTrue);
      });
    },
  );

  test('same ID equal canonical content reuses server ref, differing content needs whole-set choice', () async {
    final h = MergeHarness();
    await h.setup();
    addTearDown(h.controller.dispose);
    final same = await h.controller.propose(
      local: h.local([mergeProfile(10)]),
      remote: h.remote([mergeProfile(10)]),
    );
    expect(same.conflicts, isEmpty);
    await h.controller.confirm(same, SyncMergeChoice.automatic, (grant) async {
      expect(grant.target.needsPublication, isFalse);
      expect(grant.target.records.single.source, SyncMergeSource.server);
    });
    final different = await h.controller.propose(
      local: h.local([mergeProfile(10, name: 'local'), mergeProfile(20)]),
      remote: h.remote([mergeProfile(10, name: 'server'), mergeProfile(30)]),
    );
    expect(
      different.conflicts.single.reason,
      SyncMergeConflictKind.firstDifferentId,
    );
    expect(different.merged, isNull);
    await expectLater(
      h.controller.confirm(
        different,
        SyncMergeChoice.automatic,
        (_) async => null,
      ),
      throwsA(isA<OperationFailure>()),
    );
    await h.controller.confirm(different, SyncMergeChoice.server, (
      grant,
    ) async {
      expect(grant.target.records.map((r) => r.id), [mergeId(10), mergeId(30)]);
      expect(grant.target.needsPublication, isFalse);
    });
  });

  test('cancel preview and cancel head recheck preserve both sets and dispatch no effect', () async {
    final h = MergeHarness();
    await h.setup();
    addTearDown(h.controller.dispose);
    final local = h.local([mergeProfile(10)]),
        remote = h.remote([mergeProfile(20)]);
    var effects = 0;
    final before = h.root.domain.committedWrites;
    final preview = await h.controller.propose(local: local, remote: remote);
    h.controller.cancel();
    await expectLater(
      h.controller.confirm(preview, SyncMergeChoice.automatic, (_) async {
        effects++;
      }),
      throwsA(isA<OperationFailure>()),
    );
    final again = await h.controller.propose(local: local, remote: remote);
    final gate = Completer<void>();
    h.access.gate = gate;
    final execution = h.controller.confirm(again, SyncMergeChoice.automatic, (
      _,
    ) async {
      effects++;
    });
    h.controller.cancel();
    await expectLater(execution, throwsA(isA<SyncTransportCancelled>()));
    gate.complete();
    expect(effects, 0);
    expect(h.root.domain.committedWrites, before);
    expect(local.counts.profiles, 1);
    expect(remote.counts.profiles, 1);
  });

  test(
    'local edit or cloud head change invalidates consent before callback',
    () async {
      for (final localEdit in [false, true]) {
        final h = MergeHarness();
        await h.setup();
        addTearDown(h.controller.dispose);
        final preview = await h.controller.propose(
          local: h.local([mergeProfile(10)]),
          remote: h.remote([mergeProfile(20)]),
        );
        var effects = 0;
        if (localEdit)
          h.root.domain.state.settings.dataRevision++;
        else
          h.remote([mergeProfile(20, name: 'new revision')], revision: 2);
        await expectLater(
          h.controller.confirm(preview, SyncMergeChoice.automatic, (_) async {
            effects++;
          }),
          throwsA(isA<OperationFailure>()),
        );
        expect(effects, 0);
      }
    },
  );

  test(
    'no key readiness or saved recovery confirmation means no execution',
    () async {
      final h = MergeHarness();
      await h.setup();
      addTearDown(h.controller.dispose);
      h.ready = false;
      final preview = await h.controller.propose(
        local: h.local([mergeProfile(10)]),
        remote: h.emptyRemote(),
      );
      var effects = 0;
      await expectLater(
        h.controller.confirm(preview, SyncMergeChoice.automatic, (_) async {
          effects++;
        }),
        throwsA(
          isA<OperationFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.authRequired,
          ),
        ),
      );
      expect(effects, 0);
      h.ready = true;
      await h.controller.confirm(preview, SyncMergeChoice.automatic, (_) async {
        effects++;
      });
      expect(effects, 1);
    },
  );

  test('execution capability is scoped and single-use; final write rechecks source', () async {
    final h = MergeHarness();
    await h.setup();
    addTearDown(h.controller.dispose);
    final preview = await h.controller.propose(
      local: h.local([mergeProfile(10)]),
      remote: h.emptyRemote(),
    );
    SyncMergeAuthorization? held;
    final gate = Completer<void>();
    final run = h.controller.confirm(preview, SyncMergeChoice.automatic, (
      grant,
    ) async {
      held = grant;
      await gate.future;
      grant.check();
    });
    await Future<void>.delayed(Duration.zero);
    expect(held!.isCurrent(), isTrue);
    h.root.domain.state.syncState.syncGeneration++;
    expect(held!.isCurrent(), isFalse);
    gate.complete();
    await expectLater(run, throwsA(isA<OperationFailure>()));
    expect(held!.isCurrent(), isFalse);
    await expectLater(
      h.controller.confirm(
        preview,
        SyncMergeChoice.automatic,
        (_) async => null,
      ),
      throwsA(isA<OperationFailure>()),
    );
  });

  test('known rollback rejects; missing base requires fresh explicit composition consent', () async {
    final h = MergeHarness();
    await h.setup();
    addTearDown(h.controller.dispose);
    h.root.domain.state.syncState.baseRevision = 2;
    await expectLater(
      h.controller.propose(
        local: h.local([mergeProfile(10)]),
        remote: h.remote([mergeProfile(20)], revision: 1),
      ),
      throwsA(isA<OperationFailure>()),
    );
    final preview = await h.controller.propose(
      local: h.local([mergeProfile(10)]),
      remote: h.remote([mergeProfile(20)], revision: 3),
    );
    expect(preview.baseUnavailable, isTrue);
    expect(preview.requiresConsent, isTrue);
  });
}
