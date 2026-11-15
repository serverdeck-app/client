import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:dartssh2/src/hostkey/hostkey_rsa.dart';
import 'package:serverdeck/connections/private_signer.dart';
import 'package:serverdeck/profiles/credential_parser.dart';
import 'package:serverdeck/profiles/key_envelope.dart'
    show PublicKeyHint, readPublicKeyHint;
import 'package:serverdeck/profiles/key_parse_worker.dart';
import 'package:serverdeck/runtime/owned_work.dart';
import 'package:serverdeck/runtime/platform_ports.dart';
import 'package:serverdeck/storage/records.dart';
import 'package:serverdeck/sync/sync_apply.dart';
import 'package:serverdeck/sync/sync_crypto.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_recovery.dart';
import 'package:serverdeck/sync/sync_repository.dart';
import 'package:serverdeck/sync/sync_transport.dart';
import 'package:serverdeck/sync/sync_wire.dart';

import '../fixtures/domain_repository.dart';
import 'transport_test.dart' as wire;

Uint8List fixture(String name) =>
    File('test/fixtures/ssh/$name.txt').readAsBytesSync();

class Authority implements SyncVaultAccess {
  Authority(this.repository, this.context);
  final MemoryDomainRepository repository;
  final SyncVaultContext context;
  bool live = true;
  @override
  void guardVaultContext(SyncVaultContext value) {
    if (!live || !value.fence.matches(repository.state.syncState))
      throw const SyncTransportCancelled();
  }

  @override
  bool isVaultContextCurrent(SyncVaultContext value) => live;
  @override
  Future<SyncVaultContext> vaultContext() async => context;
  @override
  Future<SyncHead> readVaultHead(
    SyncVaultContext context,
    SyncCancellation cancel,
  ) => throw UnimplementedError();
  @override
  Future<Uint8List> readVaultRoot(
    SyncVaultContext context,
    SyncManifest manifest,
    SyncCancellation cancel,
  ) => throw UnimplementedError();
}

class LocalSecrets implements PlatformSecretPort {
  Uint8List original = Uint8List.fromList(utf8.encode(' synthetic\n'));
  final inputs = <Uint8List>[],
      outputs = <Uint8List>[],
      protectedPlain = <Uint8List>[];
  final purposes = <String>[];
  Future<void>? delayProtect, delayUnprotect;
  bool failProtect = false, failUnprotect = false;
  int protectCalls = 0, unprotectCalls = 0;
  @override
  Future<Uint8List> protect(Uint8List bytes, String purpose) async {
    protectCalls++;
    inputs.add(bytes);
    purposes.add(purpose);
    protectedPlain.add(Uint8List.fromList(bytes));
    if (delayProtect != null) await delayProtect;
    if (failProtect) throw StateError('synthetic secret sentinel');
    final result = Uint8List.fromList([9, 8, 7]);
    outputs.add(result);
    return result;
  }

  @override
  Future<Uint8List> unprotect(Uint8List bytes, String purpose) async {
    unprotectCalls++;
    inputs.add(bytes);
    purposes.add(purpose);
    if (delayUnprotect != null) await delayUnprotect;
    if (failUnprotect) throw StateError('synthetic secret sentinel');
    final result = Uint8List.fromList(original);
    outputs.add(result);
    return result;
  }
}

class Inspector implements KeyInspector {
  int calls = 0;
  final inputs = <Uint8List>[];
  Future<void>? delay;
  KeyInspection? overrideResult;
  @override
  Future<KeyInspection> inspect(
    Uint8List bytes, {
    String? passphrase,
    WorkCancellation? cancellation,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls++;
    inputs.add(bytes);
    expect(passphrase, isNull);
    cancellation?.check();
    if (delay != null) await delay;
    cancellation?.check();
    if (overrideResult != null) return overrideResult!;
    final parsed = parsePrivateKey(bytes);
    try {
      return parsed.inspection;
    } finally {
      parsed.dispose();
    }
  }
}

class Harness {
  final domain = MemoryDomainRepository(),
      secrets = LocalSecrets(),
      inspector = Inspector();
  late final SyncFence fence;
  late final Authority access;
  late final SyncCredentialTransfer transfer;
  late final SyncTransferSnapshot snapshot;
  Future<void> setup() async {
    final repo = SyncRepository(
      domain,
      availableStorageBytes: () async => 100 * 1024 * 1024 * 1024,
    );
    fence = await repo.bind(
      expectedGeneration: 1,
      identity: SyncIdentity(
        serviceOrigin: wire.origin.value,
        accountId: wire.id(1),
        deviceId: wire.id(2),
        vaultId: wire.id(3),
      ),
      secrets: SyncSecretRecord()
        ..protectedAccess = [1]
        ..protectedRefresh = [2]
        ..protectedStatusProof = [3],
    );
    access = Authority(domain, SyncVaultContext(fence, 1));
    transfer = SyncCredentialTransfer(
      repository: domain,
      secrets: secrets,
      inspector: inspector,
      access: access,
    );
    snapshot = transfer.capture(access.context);
  }

  PortableSyncProfile content({Uint8List? original, KeyInspection? key}) =>
      PortableSyncProfile.parse({
        'kind': 'profile',
        'version': 1,
        'profile': {
          'profileId': wire.id(10),
          'displayName': 'Saved',
          'originalHost': 'EXAMPLE.test.',
          'port': 22,
          'username': 'Root',
          'createdAt': 1,
          'updatedAt': 2,
        },
        'credential': {
          'credentialId': wire.id(11),
          'kind': key == null ? 'password' : 'privateKey',
          'originalBase64': base64.encode(original ?? secrets.original),
          'publicKeyType': key?.keyType,
          'publicKeyBits': key?.bits,
          'publicKeyBase64': key == null
              ? null
              : base64.encode(key.publicKeyBytes),
        },
      });
  void source(PortableSyncProfile content) {
    final fields = content.fields;
    domain.state.profiles[content.id] = Profile()
      ..profileId = content.id
      ..displayName = fields.displayName
      ..originalHost = fields.originalHost
      ..normalizedHost = fields.normalizedHost
      ..endpointId = fields.endpointId
      ..port = fields.port
      ..username = fields.username
      ..credentialId = content.credentialId
      ..authKind = content.credentialKind
      ..createdAt = 1
      ..updatedAt = 2
      ..profileRevision = 9
      ..connectionRevision = 8
      ..syncAutoBlocked = true;
    domain.state.credentials[content.credentialId] = Credential()
      ..credentialId = content.credentialId
      ..profileId = content.id
      ..kind = content.credentialKind
      ..protectedBytes = [7]
      ..secretRevision = 6
      ..publicKeyType = content.publicKeyType
      ..publicKeyBits = content.publicKeyBits
      ..publicKeyBytes = content.copyPublicKey();
    secrets.original = content.copyOriginal();
  }
}

KeyInspection inspection(Uint8List bytes, {bool encrypted = false}) {
  final parsed = parsePrivateKey(
    bytes,
    passphrase: encrypted ? 'serverdeck-unit-passphrase' : null,
  );
  try {
    return parsed.inspection;
  } finally {
    parsed.dispose();
  }
}

void main() {
  test('native original over limits or invalid UTF8 cannot enter a portable object', () async {
    for (final original in [
      Uint8List(65537),
      Uint8List.fromList([0xc0, 0xaf]),
    ]) {
      final h = Harness();
      await h.setup();
      final content = h.content();
      h.source(content);
      content.dispose();
      h.secrets.original = original;
      await expectLater(
        h.transfer.withExportedProfile(
          h.snapshot,
          wire.id(10),
          (_, __) => 1,
          cancellation: WorkCancellation(),
        ),
        throwsA(isA<OperationFailure>()),
      );
      expect(
        h.secrets.outputs.every((bytes) => bytes.every((byte) => byte == 0)),
        isTrue,
      );
      expect(h.inspector.calls, 0);
    }
  });
  test(
    'private export encrypts exact password bytes and excludes local metadata',
    () async {
      final h = Harness();
      await h.setup();
      h.secrets.original = Uint8List.fromList(utf8.encode('\ufeff  Привет\n'));
      final content = h.content();
      h.source(content);
      content.dispose();
      final crypto = SyncCrypto(
        identity: h.fence.identity,
        rootKey: Uint8List(32),
      );
      addTearDown(crypto.dispose);
      final before = h.domain.committedWrites;
      final exported = await h.transfer.exportEncryptedProfile(
        h.snapshot,
        wire.id(10),
        crypto,
        cancellation: WorkCancellation(),
      );
      final decoded = crypto.decryptContent(
        envelope: exported.ciphertext,
        expected: exported.entry,
      ) as PortableSyncProfile;
      expect(decoded.copyOriginal(), h.secrets.original);
      expect(
        decoded.profile.keys,
        unorderedEquals([
          'profileId',
          'displayName',
          'originalHost',
          'port',
          'username',
          'createdAt',
          'updatedAt',
        ]),
      );
      expect(decoded.toJson().toString(), isNot(contains('protectedBytes')));
      expect(decoded.toJson().toString(), isNot(contains('profileRevision')));
      expect(h.domain.committedWrites, before);
      expect(h.secrets.purposes, ['credential.v1:${wire.id(11)}']);
      expect(
        h.secrets.inputs.every((bytes) => bytes.every((byte) => byte == 0)),
        isTrue,
      );
      expect(
        h.secrets.outputs.every((bytes) => bytes.every((byte) => byte == 0)),
        isTrue,
      );
      final ciphertext = exported.ciphertext;
      decoded.dispose();
      exported.dispose();
      expect(ciphertext.every((b) => b == 0), isTrue);
    },
  );

  test('password import wraps original bytes with canonical purpose without writing domain', () async {
    final h = Harness();
    await h.setup();
    final profile = h.content();
    addTearDown(profile.dispose);
    final before = h.domain.committedWrites;
    final prepared = await h.transfer.prepareImported(
      h.snapshot,
      profile,
      cancellation: WorkCancellation(),
    );
    expect(prepared.proof, SyncCredentialProof.password);
    expect(prepared.inspection, isNull);
    expect(h.secrets.protectedPlain.single, profile.copyOriginal());
    expect(h.inspector.calls, 0);
    final record = prepared.copyRecord(secretRevision: 4);
    expect(record.secretRevision, 4);
    expect(record.profileId, profile.id);
    expect(record.protectedBytes, [9, 8, 7]);
    expect(h.domain.committedWrites, before);
    expect(h.domain.state.profiles, isEmpty);
    final bytes = prepared.protectedBytes;
    prepared.dispose();
    expect(bytes, [0, 0, 0]);
    expect(record.protectedBytes, [9, 8, 7]);
    expect(() => prepared.protectedBytes, throwsA(isA<OperationFailure>()));
    expect(prepared.toString(), 'SyncPreparedCredential(redacted)');
    expect(
      h.secrets.inputs.every((bytes) => bytes.every((byte) => byte == 0)),
      isTrue,
    );
    expect(
      h.secrets.outputs.every((bytes) => bytes.every((byte) => byte == 0)),
      isTrue,
    );
  });

  for (final name in [
    'ed25519',
    'rsa2048',
    'rsa-pem-plain',
    'ed25519-encrypted',
    'rsa2048-encrypted',
    'rsa-pem-aes-128-cbc',
    'rsa-pem-aes-192-cbc',
    'rsa-pem-aes-256-cbc',
    'rsa-pem-des-ede3-cbc',
  ]) {
    test('original $name transfers without any passphrase input', () async {
      final h = Harness();
      await h.setup();
      final original = fixture(name);
      final key = inspection(
        original,
        encrypted: name.contains('encrypted') || name.contains('-cbc'),
      );
      final profile = h.content(original: original, key: key);
      addTearDown(profile.dispose);
      final prepared = await h.transfer.prepareImported(
        h.snapshot,
        profile,
        cancellation: WorkCancellation(),
      );
      expect(prepared.inspection!.keyType, key.keyType);
      expect(h.secrets.protectedPlain.single, original);
      expect(h.inspector.calls, key.encrypted ? 0 : 1);
      expect(
        prepared.proof,
        !key.encrypted
            ? SyncCredentialProof.validatedPrivateKey
            : name.startsWith('rsa-pem')
            ? SyncCredentialProof.encryptedLegacyMetadataOnly
            : SyncCredentialProof.encryptedPublicEnvelope,
      );
      expect(
        h.secrets.purposes.single,
        'credential.v1:${profile.credentialId}',
      );
      prepared.dispose();
      h.source(profile);
      final crypto = SyncCrypto(
        identity: h.fence.identity,
        rootKey: Uint8List(32),
      );
      try {
        final exported = await h.transfer.exportEncryptedProfile(
          h.snapshot,
          profile.id,
          crypto,
          cancellation: WorkCancellation(),
        );
        final decoded = crypto.decryptContent(
          envelope: exported.ciphertext,
          expected: exported.entry,
        ) as PortableSyncProfile;
        try {
          expect(decoded.copyOriginal(), original);
          expect(
            (decoded.toJson()['credential']! as Map).containsKey('passphrase'),
            isFalse,
          );
        } finally {
          decoded.dispose();
          exported.dispose();
        }
      } finally {
        crypto.dispose();
      }
      expect(
        h.secrets.inputs.every((bytes) => bytes.every((byte) => byte == 0)),
        isTrue,
      );
    });
  }

  test(
    'malformed original and public-hint substitution reject before protection',
    () async {
      final h = Harness();
      await h.setup();
      final key = inspection(fixture('ed25519'));
      for (final original in [
        Uint8List.fromList([1, 2, 3]),
        fixture('rsa2048-encrypted'),
      ]) {
        final content = h.content(original: original, key: key);
        addTearDown(content.dispose);
        await expectLater(
          h.transfer.prepareImported(
            h.snapshot,
            content,
            cancellation: WorkCancellation(),
          ),
          throwsA(isA<OperationFailure>()),
        );
      }
      expect(h.secrets.protectCalls, 0);
      final profile = h.content(original: fixture('ed25519'), key: key);
      addTearDown(profile.dispose);
      h.inspector.overrideResult = inspection(fixture('rsa2048'));
      await expectLater(
        h.transfer.prepareImported(
          h.snapshot,
          profile,
          cancellation: WorkCancellation(),
        ),
        throwsA(isA<OperationFailure>()),
      );
      expect(h.secrets.protectCalls, 0);
    },
  );

  test('legacy encrypted PEM public/private binding remains explicitly metadata-only', () async {
    final h = Harness();
    await h.setup();
    final legacy = fixture('rsa-pem-aes-256-cbc');
    final original = inspection(legacy, encrypted: true);
    final public = SSHRsaPublicKey.decode(
      Uint8List.fromList(original.publicKeyBytes),
    );
    final substituted = PublicKeyHint.decode(
      SSHRsaPublicKey(public.e, public.n + BigInt.two).encode(),
      encrypted: true,
    );
    // A distinct structurally valid public hint cannot be disproved without
    // the phrase. The source-type/size constraints remain required.
    final content = h.content(original: legacy, key: substituted.inspection);
    addTearDown(content.dispose);
    final prepared = await h.transfer.prepareImported(
      h.snapshot,
      content,
      cancellation: WorkCancellation(),
    );
    expect(prepared.proof, SyncCredentialProof.encryptedLegacyMetadataOnly);
    expect(prepared.inspection!.encrypted, isTrue);
    expect(h.inspector.calls, 0);
    expect(h.domain.state.grants, isEmpty);
    prepared.dispose();
    final signer = PrivateSigner();
    try {
      await expectLater(
        signer.sign(
          legacy,
          PrivateSignatureScheme.rsa256,
          Uint8List.fromList([1, 2, 3]),
          expectedPublicKey: substituted.encoded,
          passphrase: 'serverdeck-unit-passphrase',
        ),
        throwsA(
          isA<OperationFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.unsupportedKey,
          ),
        ),
      );
    } finally {
      await signer.dispose();
    }
    expect(
      () => parsePrivateKey(legacy),
      throwsA(
        isA<OperationFailure>().having(
          (e) => e.code,
          'code',
          FailureCode.passphraseRequired,
        ),
      ),
    );
  });

  test(
    'transferred private metadata cannot bypass manual signing admission',
    () async {
      final h = Harness();
      await h.setup();
      final legacy = fixture('rsa-pem-aes-256-cbc'),
          key = inspection(legacy, encrypted: true);
      final content = h.content(original: legacy, key: key);
      addTearDown(content.dispose);
      final prepared = await h.transfer.prepareImported(
        h.snapshot,
        content,
        cancellation: WorkCancellation(),
      );
      final signer = PrivateSigner();
      var prompts = 0;
      final identity = OwnedPrivateIdentity(
        file: legacy,
        credentialRevision: 1,
        expected: prepared.inspection!,
        publicHint: readPublicKeyHint(
          legacy,
          publicKeyBytes: key.publicKeyBytes,
        ),
        signer: signer,
        checkAdmission: (_) {
          throw const OperationFailure(FailureCode.accessRevoked);
        },
        serverAlgorithms: () => ['rsa-sha2-256'],
        requestPassphrase: () async {
          prompts++;
          return 'serverdeck-unit-passphrase';
        },
        remainingBudget: () => const Duration(seconds: 30),
      );
      try {
        await expectLater(
          identity.sign(Uint8List.fromList([1])),
          throwsA(
            isA<OperationFailure>().having(
              (e) => e.code,
              'code',
              FailureCode.accessRevoked,
            ),
          ),
        );
        expect(prompts, 0);
        expect(signer.activeWorkers, 0);
      } finally {
        identity.dispose();
        prepared.dispose();
        await signer.dispose();
      }
    },
  );

  test(
    'stale profile edit after unprotect or inspector completion rejects export',
    () async {
      for (final parse in [false, true]) {
        final h = Harness();
        await h.setup();
        final content = parse
            ? h.content(
                original: fixture('ed25519'),
                key: inspection(fixture('ed25519')),
              )
            : h.content();
        h.source(content);
        content.dispose();
        final gate = Completer<void>();
        if (parse)
          h.inspector.delay = gate.future;
        else
          h.secrets.delayUnprotect = gate.future;
        final exporting = h.transfer.withExportedProfile(
          h.snapshot,
          wire.id(10),
          (profile, proof) => profile.id,
          cancellation: WorkCancellation(),
        );
        await Future<void>.delayed(Duration.zero);
        h.domain.state.settings.dataRevision++;
        gate.complete();
        await expectLater(
          exporting,
          throwsA(
            isA<OperationFailure>().having(
              (e) => e.code,
              'code',
              FailureCode.conflict,
            ),
          ),
        );
        expect(
          h.secrets.outputs.every((bytes) => bytes.every((byte) => byte == 0)),
          isTrue,
        );
        expect(
          h.inspector.inputs.every((bytes) => bytes.every((byte) => byte == 0)),
          isTrue,
        );
      }
    },
  );

  test('cancellation, account fencing and single admission retain no new credential', () async {
    for (final cancel in [false, true]) {
      final h = Harness();
      await h.setup();
      final profile = h.content();
      addTearDown(profile.dispose);
      final cancellation = WorkCancellation(), gate = Completer<void>();
      h.secrets.delayProtect = gate.future;
      final preparing = h.transfer.prepareImported(
        h.snapshot,
        profile,
        cancellation: cancellation,
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        h.transfer.prepareImported(
          h.snapshot,
          profile,
          cancellation: WorkCancellation(),
        ),
        throwsA(
          isA<OperationFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.resourceExhausted,
          ),
        ),
      );
      if (cancel)
        cancellation.cancel();
      else
        h.domain.state.syncState.identityGeneration++;
      gate.complete();
      await expectLater(
        preparing,
        throwsA(cancel ? isA<WorkCancelled>() : isA<SyncTransportCancelled>()),
      );
      expect(h.domain.state.credentials, isEmpty);
      expect(
        h.secrets.outputs.every((bytes) => bytes.every((byte) => byte == 0)),
        isTrue,
      );
      expect(
        h.secrets.inputs.every((bytes) => bytes.every((byte) => byte == 0)),
        isTrue,
      );
    }
  });

  test('native failures and corrupt stored association preserve data and safe errors', () async {
    final h = Harness();
    await h.setup();
    final profile = h.content();
    h.source(profile);
    addTearDown(profile.dispose);
    h.secrets.failProtect = true;
    await expectLater(
      h.transfer.prepareImported(
        h.snapshot,
        profile,
        cancellation: WorkCancellation(),
      ),
      throwsA(
        isA<OperationFailure>().having(
          (e) => e.code,
          'code',
          FailureCode.protectionUnavailable,
        ),
      ),
    );
    h.secrets.failUnprotect = true;
    await expectLater(
      h.transfer.withExportedProfile(
        h.snapshot,
        profile.id,
        (_, __) => 1,
        cancellation: WorkCancellation(),
      ),
      throwsA(isA<OperationFailure>()),
    );
    expect(h.domain.state.credentials[profile.credentialId]!.protectedBytes, [
      7,
    ]);
    h.secrets.failUnprotect = false;
    h.domain.state.credentials[profile.credentialId]!.profileId = wire.id(99);
    final calls = h.secrets.unprotectCalls;
    await expectLater(
      h.transfer.withExportedProfile(
        h.snapshot,
        profile.id,
        (_, __) => 1,
        cancellation: WorkCancellation(),
      ),
      throwsA(isA<OperationFailure>()),
    );
    expect(h.secrets.unprotectCalls, calls);
  });

  test('foreign crypto namespace rejects before any private unprotect; callback content is disposed', () async {
    final h = Harness();
    await h.setup();
    final content = h.content();
    h.source(content);
    content.dispose();
    final crypto = SyncCrypto(
      identity: SyncIdentity(
        serviceOrigin: 'https://other.test',
        accountId: wire.id(1),
        deviceId: wire.id(2),
        vaultId: wire.id(3),
      ),
      rootKey: Uint8List(32),
    );
    await expectLater(
      h.transfer.exportEncryptedProfile(
        h.snapshot,
        wire.id(10),
        crypto,
        cancellation: WorkCancellation(),
      ),
      throwsA(isA<OperationFailure>()),
    );
    expect(h.secrets.unprotectCalls, 0);
    crypto.dispose();
    final escaped = await h.transfer.withExportedProfile(
      h.snapshot,
      wire.id(10),
      (profile, proof) => profile,
      cancellation: WorkCancellation(),
    );
    expect(() => escaped.copyOriginal(), throwsA(isA<OperationFailure>()));
  });

  test(
    'prepared result cannot be consumed after local revision changes',
    () async {
      final h = Harness();
      await h.setup();
      final content = h.content();
      addTearDown(content.dispose);
      final prepared = await h.transfer.prepareImported(
        h.snapshot,
        content,
        cancellation: WorkCancellation(),
      );
      h.domain.state.settings.dataRevision++;
      expect(
        () => prepared.copyRecord(secretRevision: 1),
        throwsA(
          isA<OperationFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.conflict,
          ),
        ),
      );
      prepared.dispose();
    },
  );

  test('UTF8 password byte boundary preserves multibyte input without normalization', () {
    for (final value in ['a' * 65536, '😀' * 16384, '界' * 21845 + 'a']) {
      final input = PasswordInput(value);
      expect(input.password, value);
      input.dispose();
    }
    for (final value in [
      'a' * 65537,
      '😀' * 16384 + 'a',
      '界' * 21845 + 'aa',
      String.fromCharCode(0xd800),
    ]) {
      expect(() => PasswordInput(value), throwsA(isA<OperationFailure>()));
    }
  });
}
