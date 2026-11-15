import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_apply.dart';
import 'package:serverdeck/sync/sync_merge.dart';

import '../fixtures/sync_merge.dart';

void main() {
  test('equal content with different ciphertext hashes merges; timestamps never choose a winner', () async {
    final h = MergeHarness();
    await h.setup();
    final base = h.remote([mergeProfile(10)], current: false);
    final remote = h.remote([mergeProfile(10)], revision: 2);
    final plan = SyncMergePlan.build(
      local: h.local([mergeProfile(10)]),
      remote: remote,
      base: base,
    );
    expect(plan.conflicts, isEmpty);
    expect(plan.requiresConsent, isFalse);
    expect(plan.resolve(SyncMergeChoice.automatic).needsPublication, isFalse);
    final conflict = SyncMergePlan.build(
      local: h.local([mergeProfile(10, name: 'local', updated: 999999)]),
      remote: h.remote([
        mergeProfile(10, name: 'server', updated: 3),
      ], revision: 2),
      base: base,
    );
    expect(conflict.conflicts.single.reason, SyncMergeConflictKind.editEdit);
    final local = conflict.resolve(SyncMergeChoice.local);
    expect(local.records.single.source, SyncMergeSource.local);
    expect(local.needsPublication, isTrue);
    expect(local.needsLocalApply, isFalse);
  });

  test('disjoint record edits and identical concurrent edits merge deterministically', () async {
    final h = MergeHarness();
    await h.setup();
    final base = h.remote([mergeProfile(10), mergeProfile(20)], current: false);
    final plan = SyncMergePlan.build(
      local: h.local([mergeProfile(10, name: 'A'), mergeProfile(20)]),
      remote: h.remote([
        mergeProfile(10),
        mergeProfile(20, name: 'B'),
      ], revision: 2),
      base: base,
    );
    expect(plan.conflicts, isEmpty);
    final target = plan.resolve(SyncMergeChoice.automatic);
    expect(target.records.map((r) => r.source), [
      SyncMergeSource.local,
      SyncMergeSource.server,
    ]);
    expect(target.needsLocalApply, isTrue);
    expect(target.needsPublication, isTrue);
    final identical = SyncMergePlan.build(
      local: h.local([mergeProfile(10, name: 'same')]),
      remote: h.remote([mergeProfile(10, name: 'same')], revision: 2),
      base: h.remote([mergeProfile(10)], current: false),
    );
    expect(identical.conflicts, isEmpty);
  });

  test(
    'absence deletes unchanged base records; delete/edit is explicit conflict',
    () async {
      final h = MergeHarness();
      await h.setup();
      final base = h.remote([mergeProfile(10)], current: false);
      final deleted = SyncMergePlan.build(
        local: h.local([]),
        remote: h.remote([mergeProfile(10)], revision: 2),
        base: base,
      );
      expect(deleted.conflicts, isEmpty);
      expect(deleted.resolve(SyncMergeChoice.automatic).records, isEmpty);
      final conflict = SyncMergePlan.build(
        local: h.local([]),
        remote: h.remote([mergeProfile(10, name: 'edit')], revision: 2),
        base: base,
      );
      expect(
        conflict.conflicts.single.reason,
        SyncMergeConflictKind.deleteEdit,
      );
      expect(conflict.resolve(SyncMergeChoice.local).records, isEmpty);
      expect(
        conflict.resolve(SyncMergeChoice.server).records.single.id,
        mergeId(10),
      );
    },
  );

  test(
    'profile delete versus added card cannot produce an orphan automatically',
    () async {
      final h = MergeHarness();
      await h.setup();
      final base = h.remote([mergeProfile(10)], current: false);
      final plan = SyncMergePlan.build(
        local: h.local([]),
        remote: h.remote([mergeProfile(10), mergeCard(20, 10)], revision: 2),
        base: base,
      );
      expect(
        plan.conflicts.single.reason,
        SyncMergeConflictKind.missingProfile,
      );
      expect(
        () => plan.resolve(SyncMergeChoice.automatic),
        throwsA(isA<OperationFailure>()),
      );
      expect(plan.resolve(SyncMergeChoice.local).records, isEmpty);
      expect(plan.resolve(SyncMergeChoice.server).records.length, 2);
    },
  );

  test(
    'credential ID collision after union requires coherent whole-set choice',
    () async {
      final h = MergeHarness();
      await h.setup();
      final plan = SyncMergePlan.build(
        local: h.local([mergeProfile(10, credential: 90)]),
        remote: h.remote([mergeProfile(20, credential: 90)]),
      );
      expect(
        plan.conflicts.single.reason,
        SyncMergeConflictKind.duplicateCredential,
      );
      expect(
        plan.resolve(SyncMergeChoice.local).records.single.id,
        mergeId(10),
      );
      expect(
        plan.resolve(SyncMergeChoice.server).records.single.id,
        mergeId(20),
      );
    },
  );

  test(
    'union quota overflow is a choice, never truncation or implicit deletion',
    () async {
      final h = MergeHarness();
      await h.setup();
      final local = h.local(List.generate(1000, (i) => mergeProfile(i + 1)));
      final remote = h.remote(
        List.generate(1000, (i) => mergeProfile(i + 1001)),
      );
      final plan = SyncMergePlan.build(local: local, remote: remote);
      expect(plan.conflicts.single.reason, SyncMergeConflictKind.limits);
      expect(plan.resolve(SyncMergeChoice.local).records.length, 1000);
      expect(plan.resolve(SyncMergeChoice.server).records.length, 1000);
    },
  );

  test(
    'per-profile card union limit detects coherent source choices',
    () async {
      final h = MergeHarness();
      await h.setup();
      final local = h.local([
        mergeProfile(1),
        ...List.generate(501, (i) => mergeCard(i + 100, 1)),
      ]);
      final remote = h.remote([
        mergeProfile(1),
        ...List.generate(501, (i) => mergeCard(i + 1000, 1)),
      ]);
      final plan = SyncMergePlan.build(local: local, remote: remote);
      expect(plan.conflicts.single.reason, SyncMergeConflictKind.limits);
      expect(plan.resolve(SyncMergeChoice.local).records.length, 502);
      expect(plan.resolve(SyncMergeChoice.server).records.length, 502);
    },
  );

  test('source duplicate IDs, orphan cards and incomplete remote source fail before plan', () async {
    final h = MergeHarness();
    await h.setup();
    final builder = SyncMergeSnapshotBuilder.local(h.root.snapshot);
    final profile = mergeProfile(10);
    builder.add(profile, proof: SyncCredentialProof.password);
    expect(
      () => builder.add(profile, proof: SyncCredentialProof.password),
      throwsA(isA<OperationFailure>()),
    );
    profile.dispose();
    final orphan = SyncMergeSnapshotBuilder.local(h.root.snapshot),
        card = mergeCard(20, 99);
    orphan.add(card);
    card.dispose();
    expect(orphan.finish, throwsA(isA<OperationFailure>()));
    final empty = SyncMergeSnapshotBuilder.emptyRemote(h.access.context),
        unexpected = mergeProfile(10);
    expect(
      () => empty.add(unexpected, proof: SyncCredentialProof.password),
      throwsA(isA<OperationFailure>()),
    );
    unexpected.dispose();
  });

  test(
    'selected local fingerprint binds every canonical portable field',
    () async {
      final h = MergeHarness();
      await h.setup();
      final target = SyncMergePlan.build(
        local: h.local([mergeProfile(10, name: 'chosen')]),
        remote: h.emptyRemote(),
      ).resolve(SyncMergeChoice.automatic);
      final equal = mergeProfile(10, name: 'chosen'),
          different = mergeProfile(10, name: 'other');
      expect(target.records.single.matchesContent(equal), isTrue);
      expect(target.records.single.matchesContent(different), isFalse);
      equal.dispose();
      different.dispose();
    },
  );
}
