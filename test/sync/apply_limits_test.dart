import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/profiles/credential_input.dart';
import 'package:serverdeck/storage/records.dart';
import 'package:serverdeck/sync/sync_merge.dart';
import 'package:serverdeck/sync/sync_models.dart';

import '../fixtures/sync_apply.dart';
import 'content_validation_test.dart' as data;

void main() {
  test('whole-local1000 profiles plus10000 cards applies despite one disjoint remote profile', () async {
    final h = ApplyHarness();
    await h.setup();
    h.feature.repository.shareUnchangedRecords = true;
    addTearDown(h.dispose);
    // Seed a legal synthetic local snapshot once; this is not a native DB.
    final state = h.feature.repository.state;
    for (var i = 0; i < 1000; i++) {
      final id = data.id(100000 + i), credential = data.id(200000 + i);
      final fields = validateProfileValues(
        displayName: 'Server$i',
        host: 'node$i.test',
        port: 22,
        username: 'root',
      );
      state.profiles[id] = Profile()
        ..profileId = id
        ..displayName = fields.displayName
        ..originalHost = fields.originalHost
        ..normalizedHost = fields.normalizedHost
        ..endpointId = fields.endpointId
        ..credentialId = credential
        ..username = 'root'
        ..createdAt = 1
        ..updatedAt = 2;
      state.credentials[credential] = Credential()
        ..credentialId = credential
        ..profileId = id
        ..protectedBytes = utf8.encode('synthetic$i');
      state.endpoints[fields.endpointId] = EndpointTrust()
        ..endpointId = fields.endpointId
        ..normalizedHost = fields.normalizedHost
        ..port = 22
        ..profileRefCount = 1;
      for (var j = 0; j < 10; j++) {
        final cardId = data.id(300000 + i * 10 + j);
        state.softwareCards[cardId] = SoftwareCardRecord()
          ..softwareId = cardId
          ..profileId = id
          ..endpointId = fields.endpointId
          ..host = fields.normalizedHost
          ..port = 22
          ..username = 'root'
          ..name = 'Service$j'
          ..createdAt = 1
          ..updatedAt = 2;
      }
    }
    state.settings
      ..dataRevision = 2
      ..profilesListRevision = 2;
    state.syncState.syncGeneration = 1;
    final remote = await h.remote([
      PortableSyncProfile.parse(data.profile(number: 900000)),
    ]);
    final preview = await h.merge.propose(
      local: await h.local(),
      remote: remote.snapshot,
    );
    expect(
      preview.conflicts.any((c) => c.reason == SyncMergeConflictKind.limits),
      isTrue,
    );
    await h.run(remote, choice: SyncMergeChoice.local);
    final after = h.feature.repository.state;
    expect(after.profiles.length, 1000);
    expect(after.softwareCards.length, 10000);
    expect(after.profiles.containsKey(data.id(900000)), isFalse);
    expect(after.syncState.baseRevision, 1);
    final pending = after.syncRoots[after.syncState.pendingRootId]!;
    expect(pending.objectHashes.length, 11000);
    expect(after.syncState.pendingCommitId, isNotNull);
    expect(after.syncObjects.length, 11001);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
