import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_crypto.dart';
import 'package:serverdeck/sync/sync_json.dart';
import 'package:serverdeck/sync/sync_models.dart';

import 'content_validation_test.dart' as fixtures;

const account = '11111111-1111-4111-8111-111111111111';
const vault = '22222222-2222-4222-8222-222222222222';
const snapshot = '33333333-3333-4333-8333-333333333333';
SyncIdentity identity({String accountId = account, String vaultId = vault}) =>
    SyncIdentity(
      serviceOrigin: 'https://sync.test',
      accountId: accountId,
      vaultId: vaultId,
      deviceId: fixtures.id(1),
    );
Uint8List key() => Uint8List.fromList(List.generate(32, (i) => i));
Uint8List nonce(int length) =>
    Uint8List.fromList(List.generate(length, (i) => i));
List<SyncRootEntry> entries() => [
  SyncRootEntry(
    kind: 'profile',
    id: '44444444-4444-4444-8444-444444444444',
    sha256: 'bb' * 32,
    bytes: 42,
  ),
  SyncRootEntry(
    kind: 'software',
    id: '55555555-5555-4555-8555-555555555555',
    sha256: 'aa' * 32,
    bytes: 44,
  ),
];
final invalid = throwsA(isA<OperationFailure>());

// Independent test producer permits authenticated but schema-invalid plaintext.
Uint8List seal(Uint8List key, Uint8List aad, Uint8List plaintext) {
  try {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce(12), aad));
    return Uint8List.fromList([...nonce(12), ...cipher.process(plaintext)]);
  } finally {
    key.fillRange(0, key.length, 0);
    plaintext.fillRange(0, plaintext.length, 0);
  }
}

void main() {
  test(
    'independent canonical root, projection, AAD and full HKDF/GCM vector',
    () {
      final vector = File('test/fixtures/vault-vector.json').readAsStringSync();
      final expected = jsonDecode(vector) as Map<String, dynamic>;
      final expectedEnvelope = expected['envelope'] as String;
      final expectedAad = expected['aad'] as String;
      final crypto = SyncCrypto(
        identity: identity(),
        rootKey: key(),
        randomBytes: nonce,
      );
      addTearDown(crypto.dispose);
      final result = crypto.encryptRoot(
        snapshotId: snapshot,
        revision: 1,
        entries: entries(),
      );
      expect(result.objects.map((e) => e.sha256), ['aa' * 32, 'bb' * 32]);
      expect(
        syncRefsHash(result.objects),
        'ec39cb49b43eae7e40726b15a596cbd41c22946d59a1211a137aab781309de1a',
      );
      expect(
        utf8.decode(syncRootAad(identity(), snapshot, 1, result.objects)),
        expectedAad,
      );
      expect(
        syncSha256(canonicalSyncJson(result.root.toJson())),
        '6b1eddc665de27556dc9b26e43a2d41ad4d19033f6ab1dafad8f1fc567df5e0d',
      );
      final derived = crypto.deriveRootKey(snapshot);
      expect(
        derived.map((i) => i.toRadixString(16).padLeft(2, '0')).join(),
        '2d4b4efe4ff3b60dc5210a85b8a99e52f3171badce957e6d775db7dc57eb66ad',
      );
      derived.fillRange(0, derived.length, 0);
      expect(base64.encode(result.envelope), expectedEnvelope);
      expect(
        crypto
            .decryptRoot(
              envelope: result.envelope,
              root: result.ref,
              objects: result.objects,
              snapshotId: snapshot,
              revision: 1,
            )
            .toJson(),
        result.root.toJson(),
      );
    },
  );

  test(
    'objects round trip with fresh nonce; owned key and content are retained',
    () {
      final inputKey = key();
      final crypto = SyncCrypto(identity: identity(), rootKey: inputKey);
      addTearDown(crypto.dispose);
      inputKey.fillRange(0, 32, 0);
      final content = PortableSyncProfile.parse(fixtures.profile());
      addTearDown(content.dispose);
      final a = crypto.encryptContent(content),
          b = crypto.encryptContent(content);
      expect(a, isNot(b));
      final ref = SyncRootEntry(
        kind: content.kind,
        id: content.id,
        sha256: syncSha256(a),
        bytes: a.length,
      );
      final decoded = crypto.decryptContent(envelope: a, expected: ref);
      addTearDown(decoded.dispose);
      expect(decoded.toJson(), content.toJson());
      expect(content.copyOriginal(), isNotEmpty);
      crypto.dispose();
      crypto.dispose();
      expect(() => crypto.encryptContent(content), invalid);
      expect(() => crypto.deriveRootKey(snapshot), invalid);
    },
  );

  test(
    'object hash/length, namespace, kind/id, nonce, tag and wrong key reject',
    () {
      final crypto = SyncCrypto(
        identity: identity(),
        rootKey: key(),
        randomBytes: nonce,
      );
      addTearDown(crypto.dispose);
      final content = PortableSyncProfile.parse(fixtures.profile());
      addTearDown(content.dispose);
      final bytes = crypto.encryptContent(content);
      SyncRootEntry ref(
        Uint8List b, {
        String kind = 'profile',
        String? id,
        int? length,
      }) => SyncRootEntry(
        kind: kind,
        id: id ?? content.id,
        sha256: syncSha256(b),
        bytes: length ?? b.length,
      );
      expect(
        () => crypto.decryptContent(
          envelope: bytes,
          expected: ref(bytes, length: bytes.length + 1),
        ),
        invalid,
      );
      expect(
        () => crypto.decryptContent(
          envelope: bytes,
          expected: ref(bytes, id: fixtures.id(999)),
        ),
        invalid,
      );
      expect(
        () => crypto.decryptContent(
          envelope: bytes,
          expected: ref(bytes, kind: 'software'),
        ),
        invalid,
      );
      for (final offset in [0, 12, bytes.length - 1]) {
        final changed = Uint8List.fromList(bytes)..[offset] ^= 1;
        expect(
          () =>
              crypto.decryptContent(envelope: changed, expected: ref(changed)),
          invalid,
        );
        expect(
          () => crypto.decryptContent(envelope: changed, expected: ref(bytes)),
          invalid,
        );
      }
      for (final other in [
        SyncCrypto(
          identity: identity(accountId: fixtures.id(2)),
          rootKey: key(),
        ),
        SyncCrypto(
          identity: identity(vaultId: fixtures.id(2)),
          rootKey: key(),
        ),
        SyncCrypto(identity: identity(), rootKey: Uint8List(32)),
      ]) {
        addTearDown(other.dispose);
        expect(
          () => other.decryptContent(envelope: bytes, expected: ref(bytes)),
          invalid,
        );
      }
    },
  );

  test('root header substitutions and private/public reordering reject', () {
    final crypto = SyncCrypto(
      identity: identity(),
      rootKey: key(),
      randomBytes: nonce,
    );
    addTearDown(crypto.dispose);
    final result = crypto.encryptRoot(
      snapshotId: snapshot,
      revision: 1,
      entries: entries(),
    );
    void decrypt({
      String snapshotId = snapshot,
      int revision = 1,
      List<SyncBlobRef>? objects,
      SyncBlobRef? root,
    }) => crypto.decryptRoot(
      envelope: result.envelope,
      root: root ?? result.ref,
      objects: objects ?? result.objects,
      snapshotId: snapshotId,
      revision: revision,
    );
    expect(() => decrypt(snapshotId: fixtures.id(1)), invalid);
    expect(() => decrypt(revision: 2), invalid);
    expect(() => decrypt(objects: result.objects.reversed.toList()), invalid);
    expect(
      () => decrypt(
        objects: [
          SyncBlobRef(result.objects.first.sha256, 45),
          result.objects.last,
        ],
      ),
      invalid,
    );
    expect(
      () => decrypt(root: SyncBlobRef('00' * 32, result.ref.bytes)),
      invalid,
    );
    expect(
      () => decrypt(root: SyncBlobRef(result.ref.sha256, result.ref.bytes + 1)),
      invalid,
    );
    expect(
      () => crypto.encryptRoot(
        snapshotId: snapshot,
        revision: 1,
        entries: entries().reversed.toList(),
      ),
      invalid,
    );
    expect(
      () => syncRefsHash([result.objects.first, result.objects.first]),
      invalid,
    );
  });

  test(
    'invalid sizes/UUID/revision/random source fail safely without secrets',
    () {
      expect(
        () => SyncCrypto(identity: identity(), rootKey: Uint8List(31)),
        invalid,
      );
      final crypto = SyncCrypto(
        identity: identity(),
        rootKey: key(),
        randomBytes: (_) => Uint8List(11),
      );
      addTearDown(crypto.dispose);
      expect(
        () =>
            crypto.encryptRoot(snapshotId: snapshot, revision: 1, entries: []),
        invalid,
      );
      expect(() => crypto.deriveRootKey('secret material'), invalid);
      expect(() => syncRootAad(identity(), snapshot, 0, []), invalid);
      expect(
        () => crypto.decryptRoot(
          envelope: Uint8List(27),
          root: SyncBlobRef('00' * 32, 27),
          objects: [],
          snapshotId: snapshot,
          revision: 1,
        ),
        invalid,
      );
      expect(
        () => crypto.decryptRoot(
          envelope: Uint8List(syncMaxRootBytes + 1),
          root: SyncBlobRef('00' * 32, syncMaxRootBytes + 1),
          objects: [],
          snapshotId: snapshot,
          revision: 1,
        ),
        invalid,
      );
      try {
        crypto.deriveRootKey('secret material');
      } catch (error) {
        expect(error.toString(), isNot(contains('secret material')));
      }
      expect(crypto.toString(), isNot(contains(base64.encode(key()))));
    },
  );
  test(
    'authenticated content still requires canonical JSON and exact identity',
    () {
      final crypto = SyncCrypto(identity: identity(), rootKey: key());
      addTearDown(crypto.dispose);
      final content = fixtures.profile();
      final profileId = fixtures.id(10);
      for (final plaintext in [
        Uint8List.fromList(utf8.encode(' ${jsonEncode(content)}')),
        canonicalSyncJson({...content, 'extra': 'secret sentinel'}),
        canonicalSyncJson(fixtures.profile(number: 99)),
        Uint8List.fromList([0xff]),
      ]) {
        final envelope = seal(
          crypto.deriveObjectKey('profile', profileId),
          syncObjectAad(identity(), 'profile', profileId),
          plaintext,
        );
        expect(
          () => crypto.decryptContent(
            envelope: envelope,
            expected: SyncRootEntry(
              kind: 'profile',
              id: profileId,
              sha256: syncSha256(envelope),
              bytes: envelope.length,
            ),
          ),
          invalid,
        );
      }
      final future = {...content, 'version': 2};
      final envelope = seal(
        crypto.deriveObjectKey('profile', profileId),
        syncObjectAad(identity(), 'profile', profileId),
        canonicalSyncJson(future),
      );
      expect(
        () => crypto.decryptContent(
          envelope: envelope,
          expected: SyncRootEntry(
            kind: 'profile',
            id: profileId,
            sha256: syncSha256(envelope),
            bytes: envelope.length,
          ),
        ),
        throwsA(isA<SyncUnsupportedContentVersion>()),
      );
    },
  );

  test(
    'valid root tag does not bypass private ordering or namespace schema',
    () {
      final crypto = SyncCrypto(identity: identity(), rootKey: key());
      addTearDown(crypto.dispose);
      final root = crypto.encryptRoot(
        snapshotId: snapshot,
        revision: 1,
        entries: entries(),
      );
      for (final data in [
        {
          ...root.root.toJson(),
          'objects': entries().reversed.map((e) => e.toJson()).toList(),
        },
        {...root.root.toJson(), 'accountId': fixtures.id(8)},
        {...root.root.toJson(), 'revision': 2},
        {...root.root.toJson(), 'objects': <Object?>[]},
      ]) {
        final envelope = seal(
          crypto.deriveRootKey(snapshot),
          syncRootAad(identity(), snapshot, 1, root.objects),
          canonicalSyncJson(data),
        );
        expect(
          () => crypto.decryptRoot(
            envelope: envelope,
            root: SyncBlobRef(syncSha256(envelope), envelope.length),
            objects: root.objects,
            snapshotId: snapshot,
            revision: 1,
          ),
          invalid,
        );
      }
    },
  );

  test(
    'empty root, key domain separation, oversized inputs and RNG failures',
    () {
      final crypto = SyncCrypto(identity: identity(), rootKey: key());
      addTearDown(crypto.dispose);
      final empty = crypto.encryptRoot(
        snapshotId: snapshot,
        revision: 1,
        entries: [],
      );
      expect(
        crypto
            .decryptRoot(
              envelope: empty.envelope,
              root: empty.ref,
              objects: [],
              snapshotId: snapshot,
              revision: 1,
            )
            .entries,
        isEmpty,
      );
      final keys = [
        crypto.deriveRootKey(snapshot),
        crypto.deriveRootKey(fixtures.id(2)),
        crypto.deriveObjectKey('profile', snapshot),
        crypto.deriveObjectKey('software', snapshot),
      ];
      expect(keys.map(base64.encode).toSet().length, 4);
      for (final key in keys) {
        key.fillRange(0, key.length, 0);
      }
      expect(
        () => crypto.encryptRoot(
          snapshotId: snapshot,
          revision: 1,
          entries: List.filled(11001, entries().first),
        ),
        invalid,
      );
      expect(
        () => crypto.decryptContent(
          envelope: Uint8List(syncMaxObjectBytes + 1),
          expected: entries().first,
        ),
        invalid,
      );
      final failedRng = SyncCrypto(
        identity: identity(),
        rootKey: key(),
        randomBytes: (_) => throw StateError('secret sentinel'),
      );
      addTearDown(failedRng.dispose);
      expect(
        () => failedRng.encryptRoot(
          snapshotId: snapshot,
          revision: 1,
          entries: [],
        ),
        invalid,
      );
      try {
        failedRng.encryptRoot(snapshotId: snapshot, revision: 1, entries: []);
      } catch (error) {
        expect(error.toString(), isNot(contains('secret sentinel')));
      }
    },
  );
}
