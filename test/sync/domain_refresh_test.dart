import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/receipt_book.dart';
import 'package:serverdeck/domain/app_operations.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/profiles/profile_controller.dart';
import 'package:serverdeck/software/software_owner.dart';
import 'package:serverdeck/storage/records.dart';

import '../fixtures/domain_repository.dart';
import '../fixtures/feature_harness.dart';
import '../profiles/profile_list_actions_test.dart' show ListOperations, epoch;

import 'package:serverdeck/domain/actor.dart';

Future<void> turns() => Future<void>.delayed(Duration.zero);

class _DelayedOperations extends Fake implements AppOperations {
  final base = ListOperations();
  final gate = Completer<void>();
  bool populated = false;
  int lists = 0;
  @override
  Future<OperationResult<ProfilesPage>> listProfiles(
    Actor actor, {
    int limit = 50,
    String? cursor,
  }) async {
    final captured = populated
        ? await base.listProfiles(actor, limit: limit, cursor: cursor)
        : base.ok(ProfilesPage(items: [], snapshotRevision: 1));
    lists++;
    if (lists == 1) await gate.future;
    return captured;
  }

  @override
  Future<OperationResult<TrustView>> getTrust(Actor actor, String id) =>
      base.getTrust(actor, id);
}

void main() {
  test('commit arriving during an old refresh triggers another read before settling', () async {
    final repository = MemoryDomainRepository(),
        operations = _DelayedOperations();
    addTearDown(repository.disposeNotifications);
    final controller = ProfileController(
      operations: operations,
      actor: ActorAuthority(epoch).ui,
      newId: () => featureId(5),
      poll: false,
      domainChanges: repository.domainChanges,
    );
    addTearDown(controller.dispose);
    final loading = controller.refresh();
    await turns();
    operations.populated = true;
    await repository.write(
      (r) => r.putProfile(Profile()..profileId = featureId(1)),
    );
    await turns();
    operations.gate.complete();
    await loading;
    expect(controller.items.single.displayName, 'Fixture server');
    expect(operations.lists, 2);
  });
  test('one signal sees committed batch; rollback, receipts and sync metadata are silent', () async {
    final repository = MemoryDomainRepository();
    addTearDown(repository.disposeNotifications);
    final observed = <int>[];
    final subscription = repository.domainChanges.listen((_) {
      observed.add(repository.read((r) => r.settings.dataRevision));
    });
    addTearDown(subscription.cancel);
    await repository.write((r) {
      r.putProfile(Profile()..profileId = featureId(1));
      r.putSoftwareCard(SoftwareCardRecord()..softwareId = featureId(2));
      r.putSettings(r.settings..dataRevision = 2);
      expect(observed, isEmpty);
    });
    await turns();
    expect(observed, [2]);
    repository.failCommit = true;
    await expectLater(
      repository.write((r) {
        r.putProfile(Profile()..profileId = featureId(3));
        r.putSettings(r.settings..dataRevision = 3);
      }),
      throwsStateError,
    );
    await repository.write((r) {
      r.putSyncState(r.syncState..syncGeneration = 4);
      r.putReceipt(
        MutationReceipt()
          ..clientId = featureId(9)
          ..mutationId = 'receipt',
      );
    });
    await turns();
    expect(observed, [2]);
    expect(repository.state.profiles.containsKey(featureId(3)), isFalse);
  });

  test('repository invalidation refreshes profile data with polling disabled and detaches on dispose', () async {
    final repository = MemoryDomainRepository(), operations = ListOperations();
    addTearDown(repository.disposeNotifications);
    final controller = ProfileController(
      operations: operations,
      actor: ActorAuthority(epoch).ui,
      newId: () => featureId(5),
      poll: false,
      domainChanges: repository.domainChanges,
    );
    expect(controller.items, isEmpty);
    await repository.write(
      (r) => r.putProfile(Profile()..profileId = featureId(1)),
    );
    await turns();
    await controller.refresh();
    expect(controller.items.single.displayName, 'Fixture server');
    var changes = 0;
    controller.addListener(() => changes++);
    controller.dispose();
    await repository.write((r) => r.deleteProfile(featureId(1)));
    await turns();
    expect(changes, 0);
  });

  test('external card batch notifies SoftwareOwner once without synthetic events or dirty accounting', () async {
    final h = FeatureHarness();
    addTearDown(h.dispose);
    final owner = SoftwareOwner(
      gate: h.gate,
      repository: h.repository,
      receipts: ReceiptBook(h.signer, () => 1),
      newId: () => featureId(10),
      utcNow: () => 1,
    );
    addTearDown(owner.dispose);
    var notifications = 0;
    owner.addListener(() => notifications++);
    await h.repository.write((r) {
      r.putSoftwareCard(SoftwareCardRecord()..softwareId = featureId(1));
      r.putSoftwareCard(SoftwareCardRecord()..softwareId = featureId(2));
    });
    await turns();
    expect(notifications, 1);
    expect(h.repository.state.softwareEvents, isEmpty);
    expect(h.repository.state.syncState.syncGeneration, 0);
    await owner.stopAdmission();
    await h.repository.write((r) => r.deleteSoftwareCard(featureId(1)));
    await turns();
    expect(notifications, 1);
  });
}
