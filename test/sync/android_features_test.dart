import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/domain/mutation_receipts.dart';
import 'package:serverdeck/profiles/profile_controller.dart';
import 'package:serverdeck/runtime/feature_runtime.dart';
import 'package:serverdeck/runtime/platform_ports.dart';
import 'package:serverdeck/software/software_models.dart';
import 'package:serverdeck/sync/sync_owner.dart';

import '../fixtures/domain_repository.dart';
import '../fixtures/feature_harness.dart';
import '../fixtures/sync_lifecycle.dart' show LifecycleBrowser;
import 'transport_test.dart' as wire;

class _MobileLife implements PlatformLifecyclePort {
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

class _MobilePorts implements PlatformSecretPort, PlatformKeyPickerPort {
  final plaintextInputs = <Uint8List>[];
  final purposes = <String>[];
  @override
  Future<Uint8List> protect(Uint8List bytes, String purpose) async {
    plaintextInputs.add(bytes);
    purposes.add(purpose);
    return Uint8List.fromList(bytes.map((b) => b ^ 0xa5).toList());
  }

  @override
  Future<Uint8List> unprotect(Uint8List bytes, String purpose) async =>
      Uint8List.fromList(bytes.map((b) => b ^ 0xa5).toList());
  @override
  Future<Uint8List?> pickPrivateKey() async =>
      File('test/fixtures/ssh/ed25519-encrypted.txt').readAsBytesSync();
}

class _Mobile {
  _Mobile({MemoryDomain? saved, bool withSync = false}) {
    if (saved != null) repository.state = saved;
    features = FeatureRuntime.android(
      secrets: ports,
      keyPicker: ports,
      ownerEpoch: FeatureRuntime.newId(),
      dataRoot: 'synthetic-private-root',
      repository: repository,
      signer: ReceiptSigner(Uint8List.fromList(List.filled(32, 7))),
      isRunning: () => true,
      beginDial: (_, _) async => FeatureDial(FeatureSocket()),
      createTransport: (_, options) {
        final session = FeatureSession(options);
        sessions.add(session);
        return session;
      },
      connectionClock: clock.monotonic,
      connectionSchedule: clock.schedule,
    );
    if (withSync)
      features.configureSync(
        browser: LifecycleBrowser(),
        availableStorageBytes: () async => 100 * 1024 * 1024 * 1024,
        monotonicMicros: () => clock.elapsed.inMicroseconds,
        lifecycle: life,
        refreshClock: () async {},
        http: wire.FakeHttp(
          (_, _) async => throw StateError('No automatic login'),
        ),
      );
    controller = ProfileController(
      operations: features.operations,
      actor: features.actors.ui,
      newId: FeatureRuntime.newId,
      poll: false,
    );
  }
  final repository = MemoryDomainRepository(),
      ports = _MobilePorts(),
      clock = FeatureClock();
  final sessions = <FeatureSession>[];
  final life = _MobileLife();
  late final FeatureRuntime features;
  late final ProfileController controller;
  Future<String> create({bool key = false}) async {
    final bytes = key ? await features.keyPicker.pickPrivateKey() : null;
    final AuthenticationInput input = key
        ? PrivateKeyInput(bytes!, passphrase: 'serverdeck-unit-passphrase')
        : PasswordInput('synthetic-mobile-password');
    bytes?.fillRange(0, bytes.length, 0);
    try {
      final result = await features.profiles.createProfile(
        features.actors.ui,
        ProfileDraft(
          displayName: 'Mobile fixture',
          host: 'mobile.invalid',
          username: 'root',
          authentication: input,
        ),
        mutationId: FeatureRuntime.newId(),
      );
      expect(result.error, isNull);
      return result.value!.entityId;
    } finally {
      input.dispose();
    }
  }

  Future<FeatureSession> connect(String id) async {
    await controller.select(id);
    expect(await controller.connect(controller.details!.profile), isNull);
    await featureTurns();
    return sessions.last;
  }

  Future<void> accept(String id) async {
    await featureTurns();
    await controller.refresh();
    expect(controller.details!.connection.state, ConnectionState.needTrust);
    expect(
      await controller.decide(
        id,
        controller.details!.trust.challenge!,
        confirmed: true,
        mutationId: FeatureRuntime.newId(),
      ),
      isNull,
    );
  }

  Future<void> dispose() async {
    controller.dispose();
    await features.dispose();
    await life.controller.close();
  }
}

void main() {
  late _Mobile h;
  setUp(() async {
    h = _Mobile();
    await h.features.initialize();
  });
  tearDown(() async => h.dispose());
  test('mobile sync pause preserves process-local manual SSH while shutdown closes it', () async {
    await h.dispose();
    h = _Mobile(withSync: true);
    await h.features.initialize();
    final id = await h.create();
    final session = await h.connect(id), authenticated = session.authenticate();
    await h.accept(id);
    await authenticated;
    await featureTurns();
    h.life.emit(PlatformLifecyclePhase.paused);
    expect(h.features.sync!.owner.view.phase, SyncAuthPhase.paused);
    expect(
      h.features.connections.connection(id).state,
      ConnectionState.connected,
    );
    expect(
      (await h.features.operations.getProfile(h.features.actors.ui, id)).error,
      isNull,
    );
    h.life.emit(PlatformLifecyclePhase.resumed);
    await featureTurns();
    expect(h.features.sync!.owner.view.phase, SyncAuthPhase.disabled);
    expect(
      h.features.connections.connection(id).state,
      ConnectionState.connected,
    );
    await h.features.stopAdmission();
    await h.features.cancelPending();
    await h.features.closeSessions();
    expect(session.closed, isTrue);
  });
  test('offline Android canonical CRUD protects credentials and public projections contain no secret', () async {
    final id = await h.create();
    expect(h.features.sync, isNull);
    expect(h.repository.state.syncState.enabled, isFalse);
    final detail = (await h.features.operations.getProfile(
      h.features.actors.ui,
      id,
    )).value!;
    expect(detail.profile.host, 'mobile.invalid');
    expect(
      jsonEncode(detail.toJson()),
      isNot(contains('synthetic-mobile-password')),
    );
    expect(
      h.repository.state.credentials.values.single.protectedBytes,
      isNot(utf8.encode('synthetic-mobile-password')),
    );
    expect(
      h.ports.plaintextInputs.every((b) => b.every((v) => v == 0)),
      isTrue,
    );
    await h.controller.select(id);
    expect(
      await h.controller.update(
        h.controller.details!.profile,
        const ProfilePatch(displayName: 'Renamed mobile'),
        FeatureRuntime.newId(),
      ),
      isNull,
    );
    expect(h.repository.state.profiles[id]!.displayName, 'Renamed mobile');
    expect(
      await h.controller.delete(h.controller.details!.profile, confirmed: true),
      isNull,
    );
    expect(h.repository.state.profiles, isEmpty);
    expect(h.repository.state.credentials, isEmpty);
    expect(h.sessions, isEmpty);
  });
  test('Android encrypted picker input uses local trust and one-use passphrase callback without persisting phrase', () async {
    final id = await h.create(key: true);
    final saved = h.repository.state.credentials.values.single;
    expect(saved.kind, 'privateKey');
    expect(saved.publicKeyType, 'ssh-ed25519');
    final recovered = Uint8List.fromList(
      saved.protectedBytes.map((b) => b ^ 0xa5).toList(),
    );
    try {
      expect(
        recovered,
        File('test/fixtures/ssh/ed25519-encrypted.txt').readAsBytesSync(),
      );
    } finally {
      recovered.fillRange(0, recovered.length, 0);
    }
    final protected = List<int>.from(saved.protectedBytes);
    final session = await h.connect(id);
    session.askPassphrase = true;
    final authenticated = session.authenticate();
    await h.accept(id);
    await featureTurns();
    await h.controller.refresh();
    expect(
      h.controller.details!.connection.state,
      ConnectionState.needPassphrase,
    );
    final pending = h.controller.details!.connection.pendingInput!;
    expect(
      await h.controller.providePassphrase(
        id,
        pending,
        'serverdeck-unit-passphrase',
      ),
      isNull,
    );
    await authenticated;
    await featureTurns();
    await h.controller.refresh();
    expect(h.controller.details!.connection.state, ConnectionState.connected);
    expect(
      h.repository.state.endpoints.values.single.acceptedKeyBytes,
      isNotNull,
    );
    expect(
      await h.controller.providePassphrase(id, pending, 'second-phrase'),
      isNotNull,
    );
    expect(
      h.repository.state.credentials.values.single.protectedBytes,
      protected,
    );
    expect(h.ports.purposes.every((p) => !p.contains('passphrase')), isTrue);
    final json = jsonEncode(h.controller.details!.toJson());
    expect(json, isNot(contains('serverdeck-unit-passphrase')));
    expect(json, isNot(contains('PRIVATE KEY')));
  });
  test(
    'Android cancellation rejects late trust and cannot create local pin',
    () async {
      final id = await h.create();
      final session = await h.connect(id),
          authenticated = session.authenticate();
      await featureTurns();
      await h.controller.refresh();
      final challenge = h.controller.details!.trust.challenge!;
      expect(await h.controller.cancel(id, challenge.attemptId), isNull);
      await authenticated;
      expect(
        await h.controller.decide(
          id,
          challenge,
          confirmed: true,
          mutationId: FeatureRuntime.newId(),
        ),
        isNotNull,
      );
      expect(
        h.repository.state.endpoints.values.single.acceptedKeyBytes,
        isNull,
      );
      expect(session.closed, isTrue);
    },
  );
  test('Android software uses same canonical gate for five-field CRUD with local events', () async {
    final profile = await h.create();
    final owner = h.features.software;
    final input = SoftwareCardInput(
      name: 'Redis',
      version: '7',
      service: 'redis',
      dataPaths: ['/var/lib/redis'],
      configPaths: ['/etc/redis/redis.conf'],
    );
    final saved = await owner.save(
      h.features.actors.ui,
      profile,
      input,
      mutationId: FeatureRuntime.newId(),
    );
    expect(saved.error, isNull);
    final id = saved.value!.entityId;
    final value =
        (await owner.get(h.features.actors.ui, id)).value!.software
            as SoftwareCardView;
    expect(value.card.toJson(), input.toJson());
    final updated = await owner.save(
      h.features.actors.ui,
      profile,
      SoftwareCardInput(
        name: 'Redis renamed',
        version: null,
        service: null,
        dataPaths: [],
        configPaths: [],
      ),
      softwareId: id,
      expectedRevision: 1,
      mutationId: FeatureRuntime.newId(),
    );
    expect(updated.value!.revision, 2);
    expect(
      (await owner.save(
        h.features.actors.ui,
        profile,
        input,
        softwareId: id,
        expectedRevision: 1,
        mutationId: FeatureRuntime.newId(),
      )).error?.code,
      FailureCode.conflict,
    );
    expect(
      (await owner.delete(
        h.features.actors.ui,
        profile,
        id,
        expectedRevision: 2,
        mutationId: FeatureRuntime.newId(),
      )).error,
      isNull,
    );
    expect(h.repository.state.softwareCards, isEmpty);
    expect(h.repository.state.softwareEvents.length, 3);
    expect(h.features.consoleOwner, isNull);
    expect(h.features.journalsOwner, isNull);
    expect(h.features.monitoringOwner, isNull);
    expect(h.features.grantOwner, isNull);
    expect(h.sessions, isEmpty);
  });
  test('imported auto block survives cancelled attempt and clears only current manual trusted success', () async {
    final id = await h.create();
    await h.repository.write(
      (r) => r.putProfile(r.profile(id)!..syncAutoBlocked = true),
    );
    final first = await h.connect(id), firstAuth = first.authenticate();
    await featureTurns();
    await h.controller.refresh();
    expect(
      await h.controller.cancel(
        id,
        h.controller.details!.connection.attemptId!,
      ),
      isNull,
    );
    await firstAuth;
    expect(h.repository.state.profiles[id]!.syncAutoBlocked, isTrue);
    final second = await h.connect(id), authenticated = second.authenticate();
    await h.accept(id);
    await authenticated;
    await featureTurns();
    expect(h.repository.state.profiles[id]!.syncAutoBlocked, isFalse);
    expect(
      h.features.connections.connection(id).state,
      ConnectionState.connected,
    );
  });
  test('new Android owner process model restores saved data but no live SSH session', () async {
    final id = await h.create();
    final session = await h.connect(id), authenticated = session.authenticate();
    await h.accept(id);
    await authenticated;
    await featureTurns();
    final saved = h.repository.state.clone();
    final next = _Mobile(saved: saved);
    try {
      await next.features.initialize();
      expect(
        (await next.features.operations.getProfile(
          next.features.actors.ui,
          id,
        )).value!.profile.profileId,
        id,
      );
      expect(
        next.features.connections.connection(id).state,
        ConnectionState.disconnected,
      );
      expect(
        next.repository.state.endpoints.values.single.acceptedKeyBytes,
        isNotNull,
      );
      expect(next.sessions, isEmpty);
    } finally {
      await next.dispose();
    }
  });
}
