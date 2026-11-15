import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/domain/receipt_book.dart';
import 'package:serverdeck/software/software_models.dart';
import 'package:serverdeck/software/software_owner.dart';

import '../fixtures/profile_harness.dart';

void main() {
  late ProfileHarness h;
  late SoftwareOwner software;
  int generation() =>
      h.repository.read((records) => records.syncState.syncGeneration);
  SoftwareCardInput card([String name = 'Service']) => SoftwareCardInput(
    name: name,
    version: null,
    service: 'service',
    dataPaths: ['/data'],
    configPaths: [],
  );

  setUp(() {
    h = ProfileHarness();
    software = SoftwareOwner(
      gate: h.gate,
      repository: h.repository,
      receipts: ReceiptBook(h.signer, () => h.now),
      newId: () => fixtureId(++h.sequence),
      utcNow: () => h.now,
    );
  });
  tearDown(() async {
    await software.dispose();
    await h.dispose();
  });

  for (final mcp in [false, true]) {
    test('profile CRUD accounts once per commit, MCP=$mcp', () async {
      final actor = mcp ? h.mcp : h.actors.ui;
      final created = await h.create(actor: actor);
      expect(created.ok, isTrue);
      final id = created.value!.entityId;
      expect(generation(), 1);
      expect(
        (await h.owner.updateProfile(
          actor,
          id,
          const ProfilePatch(displayName: 'Renamed'),
          expectedRevision: 1,
          mutationId: 'rename',
        )).ok,
        isTrue,
      );
      expect(generation(), 2);
      expect(
        (await h.owner.updateProfile(
          actor,
          id,
          ProfilePatch(authentication: PasswordInput('new synthetic password')),
          expectedRevision: 2,
          mutationId: 'secret',
        )).ok,
        isTrue,
      );
      expect(generation(), 3);
      expect(
        (await h.owner.deleteProfile(
          h.actors.ui,
          id,
          expectedRevision: 3,
          confirmed: true,
        )).ok,
        isTrue,
      );
      expect(generation(), 4);
      expect(h.repository.state.credentials, isEmpty);
    });

    test(
      'card CRUD counts but event-only note and replays do not, MCP=$mcp',
      () async {
        final actor = mcp ? h.mcp : h.actors.ui;
        final profile = (await h.create(actor: actor)).value!.entityId;
        final saved = await software.save(
          actor,
          profile,
          card(),
          mutationId: 'card',
        );
        expect(saved.ok, isTrue);
        expect(generation(), 2);
        final id = saved.value!.entityId;
        final replay = await software.save(
          actor,
          profile,
          card(),
          mutationId: 'card',
        );
        expect(replay.value!.replayed, isTrue);
        expect(generation(), 2);
        expect(
          (await software.addNote(
            actor,
            profile,
            SoftwareNoteInput(
              action: 'analyze',
              summary: 'local history',
              outcome: 'success',
            ),
            softwareId: id,
            mutationId: 'note',
          )).ok,
          isTrue,
        );
        expect(generation(), 2);
        expect(
          (await software.save(
            actor,
            profile,
            card('Changed'),
            softwareId: id,
            expectedRevision: 1,
            mutationId: 'change',
          )).ok,
          isTrue,
        );
        expect(generation(), 3);
        expect(
          (await software.delete(
            actor,
            profile,
            id,
            expectedRevision: 2,
            mutationId: 'delete',
          )).ok,
          isTrue,
        );
        expect(generation(), 4);
      },
    );

    test(
      'profile receipt replay and rejected mutation leave dirty accounting unchanged, MCP=$mcp',
      () async {
        final actor = mcp ? h.mcp : h.actors.ui;
        final first = await h.create(actor: actor);
        expect((await h.create(actor: actor)).value!.replayed, isTrue);
        expect(generation(), 1);
        final rejected = await h.owner.updateProfile(
          actor,
          first.value!.entityId,
          const ProfilePatch(displayName: 'invalid revision'),
          expectedRevision: 99,
          mutationId: 'stale',
        );
        expect(rejected.error?.code, FailureCode.conflict);
        expect(generation(), 1);
      },
    );
  }

  test('failed commit rolls back data and dirty generation together', () async {
    h.repository.failCommit = true;
    expect((await h.create()).error?.code, FailureCode.storageUnavailable);
    expect(generation(), 0);
    expect(h.repository.state.profiles, isEmpty);
    final profile = (await h.create(mutation: 'next')).value!.entityId;
    h.repository.failCommit = true;
    expect(
      (await software.save(
        h.actors.ui,
        profile,
        card(),
        mutationId: 'fail',
      )).error?.code,
      FailureCode.storageUnavailable,
    );
    expect(generation(), 1);
    expect(h.repository.state.softwareCards, isEmpty);
  });

  test('generation exhaustion aborts the same profile transaction', () async {
    h.repository.state.syncState.syncGeneration = 9007199254740991;
    expect((await h.create()).error?.code, FailureCode.resourceExhausted);
    expect(h.repository.state.profiles, isEmpty);
    expect(h.repository.state.credentials, isEmpty);
    expect(generation(), 9007199254740991);
  });

  test('cascade delete is one user mutation and metadata-only writes stay excluded', () async {
    final profile = (await h.create()).value!.entityId;
    await software.save(h.actors.ui, profile, card(), mutationId: 'card');
    await h.repository.write((records) {
      final settings = records.settings;
      settings.theme = 'light';
      records.putSettings(settings);
      final endpoint = records.endpoint(records.profile(profile)!.endpointId)!;
      endpoint.changed = true;
      records.putEndpoint(endpoint);
    });
    expect(generation(), 2);
    expect(
      (await h.owner.deleteProfile(
        h.actors.ui,
        profile,
        expectedRevision: 1,
        confirmed: true,
      )).ok,
      isTrue,
    );
    expect(generation(), 3);
    expect(h.repository.state.softwareCards, isEmpty);
  });
}
