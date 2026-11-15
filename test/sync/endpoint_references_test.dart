import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/profiles/credential_input.dart';
import 'package:serverdeck/profiles/endpoint_references.dart';
import 'package:serverdeck/storage/records.dart';

import '../fixtures/domain_repository.dart';
import '../fixtures/profile_harness.dart';

Profile profile(int id, {String host = 'server.invalid'}) {
  final fields = validateProfileValues(
    displayName: 'Server',
    host: host,
    username: 'root',
  );
  return Profile()
    ..profileId = fixtureId(id)
    ..displayName = fields.displayName
    ..originalHost = fields.originalHost
    ..normalizedHost = fields.normalizedHost
    ..port = fields.port
    ..username = fields.username
    ..endpointId = fields.endpointId;
}

void main() {
  test(
    'batch keeps local accepted/observed trust when last profile is replaced',
    () async {
      final repository = MemoryDomainRepository();
      addTearDown(repository.disposeNotifications);
      final before = profile(1), after = profile(2, host: 'SERVER.invalid.');
      repository.state.endpoints[before.endpointId] = EndpointTrust()
        ..endpointId = before.endpointId
        ..normalizedHost = before.normalizedHost
        ..profileRefCount = 1
        ..trustRevision = 4
        ..observationRevision = 7
        ..acceptedKeyBytes = [1, 2]
        ..acceptedFingerprint = 'local accepted'
        ..observedKeyBytes = [3, 4]
        ..observedFingerprint = 'local observed'
        ..changed = true;
      await repository.write(
        (r) =>
            EndpointReferences.reconcile(r, before: [before], after: [after]),
      );
      final result = repository.state.endpoints[before.endpointId]!;
      expect(result.profileRefCount, 1);
      expect(result.trustRevision, 4);
      expect(result.observationRevision, 7);
      expect(result.acceptedKeyBytes, [1, 2]);
      expect(result.observedKeyBytes, [3, 4]);
      expect(result.changed, isTrue);
    },
  );

  test('net batch counts share trust; last removal deletes; new endpoint starts empty', () async {
    final repository = MemoryDomainRepository();
    addTearDown(repository.disposeNotifications);
    final a = profile(1), b = profile(2), c = profile(3, host: 'new.invalid');
    await repository.write(
      (r) => EndpointReferences.reconcile(r, before: [], after: [a, b]),
    );
    expect(repository.state.endpoints[a.endpointId]!.profileRefCount, 2);
    await repository.write(
      (r) => EndpointReferences.reconcile(r, before: [a, b], after: [b, c]),
    );
    expect(repository.state.endpoints[a.endpointId]!.profileRefCount, 1);
    final fresh = repository.state.endpoints[c.endpointId]!;
    expect(fresh.acceptedKeyBytes, isNull);
    expect(fresh.observedFingerprint, isNull);
    expect(fresh.trustRevision, 1);
    await repository.write(
      (r) => EndpointReferences.reconcile(r, before: [b, c], after: []),
    );
    expect(repository.state.endpoints, isEmpty);
  });

  test(
    'invalid count, alias and duplicate profile preserve previous trust',
    () async {
      for (final defect in ['count', 'alias', 'duplicate']) {
        final repository = MemoryDomainRepository();
        addTearDown(repository.disposeNotifications);
        final a = profile(1), b = profile(2);
        repository.state.endpoints[a.endpointId] = EndpointTrust()
          ..endpointId = a.endpointId
          ..normalizedHost = a.normalizedHost
          ..profileRefCount = defect == 'count' ? 2 : 1
          ..acceptedFingerprint = 'local';
        if (defect == 'alias') b.endpointId = '0' * 64;
        await expectLater(
          repository.write(
            (r) => EndpointReferences.reconcile(
              r,
              before: [a],
              after: defect == 'duplicate' ? [b, b] : [b],
            ),
          ),
          throwsA(anyOf(isA<OperationFailure>(), isStateError)),
        );
        expect(
          repository.state.endpoints[a.endpointId]!.acceptedFingerprint,
          'local',
        );
        expect(repository.committedWrites, 0);
      }
    },
  );

  test('partial endpoint write and commit failures restore complete previous local trust', () async {
    for (final failure in ['secondWrite', 'commit']) {
      final repository = MemoryDomainRepository();
      addTearDown(repository.disposeNotifications);
      final a = profile(1), b = profile(2, host: 'replacement.invalid');
      repository.state.endpoints[a.endpointId] = EndpointTrust()
        ..endpointId = a.endpointId
        ..normalizedHost = a.normalizedHost
        ..profileRefCount = 1
        ..trustRevision = 4
        ..observationRevision = 7
        ..acceptedKeyBytes = [1, 2]
        ..acceptedFingerprint = 'local accepted'
        ..acceptedType = 'ssh-ed25519'
        ..acceptedAt = 100
        ..observedKeyBytes = [3, 4]
        ..observedFingerprint = 'local observed'
        ..observedType = 'ssh-rsa'
        ..detectedAt = 200
        ..changed = true;
      if (failure == 'secondWrite') {
        // deleteEndpoint completes; putEndpoint then fails before writing.
        repository.failAfterWrite = 2;
      } else {
        repository.failCommit = true;
      }
      await expectLater(
        repository.write((r) {
          EndpointReferences.reconcile(r, before: [a], after: [b]);
          expect(r.endpoint(a.endpointId), isNull);
          expect(r.endpoint(b.endpointId)!.profileRefCount, 1);
        }),
        throwsStateError,
      );
      expect(repository.committedWrites, 0);
      expect(repository.state.endpoints.keys, [a.endpointId]);
      final restored = repository.state.endpoints[a.endpointId]!;
      expect(restored.profileRefCount, 1);
      expect(restored.trustRevision, 4);
      expect(restored.observationRevision, 7);
      expect(restored.acceptedKeyBytes, [1, 2]);
      expect(restored.acceptedFingerprint, 'local accepted');
      expect(restored.acceptedType, 'ssh-ed25519');
      expect(restored.acceptedAt, 100);
      expect(restored.observedKeyBytes, [3, 4]);
      expect(restored.observedFingerprint, 'local observed');
      expect(restored.observedType, 'ssh-rsa');
      expect(restored.detectedAt, 200);
      expect(restored.changed, isTrue);
    }
  });

  test(
    'single profile add/remove uses the same validated trust counts',
    () async {
      final h = ProfileHarness();
      addTearDown(h.dispose);
      final first = (await h.create()).value!.entityId;
      final second = (await h.create(mutation: 'second')).value!.entityId;
      final endpoint = h.repository.state.profiles[first]!.endpointId;
      expect(h.repository.state.endpoints[endpoint]!.profileRefCount, 2);
      await h.owner.deleteProfile(
        h.actors.ui,
        first,
        expectedRevision: 1,
        confirmed: true,
      );
      expect(h.repository.state.endpoints[endpoint]!.profileRefCount, 1);
      await h.owner.deleteProfile(
        h.actors.ui,
        second,
        expectedRevision: 1,
        confirmed: true,
      );
      expect(h.repository.state.endpoints, isEmpty);
    },
  );
}
