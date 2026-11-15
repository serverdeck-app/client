import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/src/ssh_message.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/profiles/credential_input.dart';
import 'package:serverdeck/software/software_models.dart';
import 'package:serverdeck/storage/records.dart';
import 'package:serverdeck/sync/sync_json.dart';
import 'package:serverdeck/sync/sync_models.dart';

String id(int number) =>
    '00000000-0000-4000-8000-${number.toRadixString(16).padLeft(12, '0')}';
final invalid = throwsA(isA<OperationFailure>());
Map<String, Object?> profile({int number = 10, int? credential}) => {
  'kind': 'profile',
  'version': 1,
  'profile': {
    'profileId': id(number),
    'displayName': 'Server',
    'originalHost': 'EXAMPLE.test.',
    'port': 22,
    'username': 'Root',
    'createdAt': 1,
    'updatedAt': 2,
  },
  'credential': <String, Object?>{
    'credentialId': id(credential ?? number + 1),
    'kind': 'password',
    'originalBase64': base64.encode(utf8.encode(' synthetic\n')),
    'publicKeyType': null,
    'publicKeyBits': null,
    'publicKeyBase64': null,
  },
};
Map<String, Object?> card({int number = 20, int owner = 10}) {
  final target = validateProfileValues(
    displayName: 'target',
    host: 'old.example.test',
    port: 2222,
    username: 'old',
  );
  return {
    'kind': 'software',
    'version': 1,
    'card': {
      'softwareId': id(number),
      'profileId': id(owner),
      'endpointId': target.endpointId,
      'host': target.normalizedHost,
      'port': 2222,
      'username': 'old',
      'name': 'Service',
      'version': null,
      'service': 'svc',
      'dataPaths': ['/data'],
      'configPaths': <String>[],
      'createdAt': 1,
      'updatedAt': 2,
    },
  };
}

SyncIdentity identity() => SyncIdentity(
  serviceOrigin: 'https://sync.example.test',
  accountId: id(1),
  deviceId: id(2),
  vaultId: id(3),
);
SyncRootEntry ref(PortableSyncContent content, int hash) => SyncRootEntry(
  kind: content.kind,
  id: content.id,
  sha256: hash.toRadixString(16).padLeft(64, '0'),
  bytes: canonicalSyncJson(content.toJson()).length + 28,
);
PortableSyncRoot root(List<SyncRootEntry> entries) {
  final data = {
    'version': 1,
    'accountId': id(1),
    'vaultId': id(3),
    'snapshotId': id(4),
    'revision': 1,
    'objects': entries.map((entry) => entry.toJson()).toList(),
  };
  final public =
      entries.map((entry) => SyncBlobRef(entry.sha256, entry.bytes)).toList()
        ..sort((a, b) => a.sha256.compareTo(b.sha256));
  return PortableSyncRoot.parse(
    data,
    identity: identity(),
    snapshotId: id(4),
    revision: 1,
    publicObjects: public,
    publicRoot: SyncBlobRef('f' * 64, canonicalSyncJson(data).length + 28),
  );
}

void main() {
  test(
    'exact32KiB valid local card remains portable at its allowed boundary',
    () {
      final target = validateProfileValues(
        displayName: 'target',
        host: 'example.test',
        port: 22,
        username: 'root',
      );
      final record = SoftwareCardRecord()
        ..softwareId = id(20)
        ..profileId = id(10)
        ..endpointId = target.endpointId
        ..host = target.normalizedHost
        ..port = 22
        ..username = 'root'
        ..name = 'Service'
        ..createdAt = 1
        ..updatedAt = 2
        ..dataPaths = List.generate(
          16,
          (i) => '/${i.toString().padLeft(2, '0')}${'a' * 1021}',
        )
        ..configPaths = [
          ...List.generate(
            15,
            (i) => '/${i.toString().padLeft(2, '0')}${'b' * 1021}',
          ),
          '/${'c' * 543}',
        ];
      expect(
        utf8
            .encode(
              jsonEncode(
                SoftwareCardView(record, currentTarget: true).toJson(),
              ),
            )
            .length,
        32768,
      );
      final data = {
        'kind': 'software',
        'version': 1,
        'card': {
          'softwareId': record.softwareId,
          'profileId': record.profileId,
          'endpointId': record.endpointId,
          'host': record.host,
          'port': record.port,
          'username': record.username,
          'name': record.name,
          'version': record.version,
          'service': record.service,
          'dataPaths': record.dataPaths,
          'configPaths': record.configPaths,
          'createdAt': record.createdAt,
          'updatedAt': record.updatedAt,
        },
      };
      expect(canonicalSyncJson(data).length, 32762);
      expect(PortableSyncCard.parse(data).toJson(), data);
    },
  );

  test('canonical decoder rejects excessive depth and does not echo plaintext errors', () {
    expect(
      () => strictSyncJson(
        Uint8List.fromList(utf8.encode('${'[' * 66}0${']' * 66}')),
        maxBytes: 1024,
      ),
      invalid,
    );
    try {
      strictSyncJson(
        Uint8List.fromList(utf8.encode('{"private":"synthetic password",}')),
        maxBytes: 1024,
      );
      fail('Malformed input must reject');
    } on OperationFailure catch (error) {
      expect(error.toString(), isNot(contains('synthetic password')));
    }
    final content = decodeSyncContent(canonicalSyncJson(profile()));
    expect(content.id, id(10));
    content.dispose();
  });

  test('key byte and public metadata limits are structural, not a private-key proof', () {
    final writer = SSHMessageWriter()
      ..writeUtf8('ssh-ed25519')
      ..writeString(Uint8List.fromList(List.filled(32, 7)));
    final data = profile();
    final credential = data['credential']! as Map<String, Object?>;
    credential.addAll({
      'kind': 'privateKey',
      'originalBase64': base64.encode(Uint8List(1024 * 1024)),
      'publicKeyType': 'ssh-ed25519',
      'publicKeyBits': 256,
      'publicKeyBase64': base64.encode(writer.takeBytes()),
    });
    final checked = PortableSyncProfile.parse(data);
    expect(checked.copyOriginal().length, 1024 * 1024);
    checked.dispose();
    credential['publicKeyBits'] = 512;
    expect(() => PortableSyncProfile.parse(data), invalid);
    credential['publicKeyBits'] = 256;
    credential['originalBase64'] = base64.encode(Uint8List(1024 * 1024 + 1));
    expect(() => PortableSyncProfile.parse(data), invalid);
    // Actual key envelope/public-private matching remains mandatory in T012.
  });

  test(
    'public root limits accept 11000 metadata refs and enforce per-kind limits',
    () {
      List<SyncRootEntry> entries(int profiles, int cards) => [
        for (var i = 0; i < profiles; i++)
          SyncRootEntry(
            kind: 'profile',
            id: id(i + 1),
            sha256: (i + 1).toRadixString(16).padLeft(64, '0'),
            bytes: 1,
          ),
        for (var i = 0; i < cards; i++)
          SyncRootEntry(
            kind: 'software',
            id: id(i + 1),
            sha256: (profiles + i + 1).toRadixString(16).padLeft(64, '0'),
            bytes: 1,
          ),
      ];
      expect(root(entries(1000, 10000)).entries.length, 11000);
      expect(() => root(entries(1001, 0)), invalid);
      expect(() => root(entries(0, 10001)), invalid);
    },
  );

  test('root aggregate includes ciphertext root at exact 4GiB with no payload allocation', () {
    final entries = List.generate(
      1024,
      (i) => SyncRootEntry(
        kind: 'software',
        id: id(i + 1),
        sha256: (i + 1).toRadixString(16).padLeft(64, '0'),
        bytes: syncMaxObjectBytes,
      ),
    );
    final header = {
      'version': 1,
      'accountId': id(1),
      'vaultId': id(3),
      'snapshotId': id(4),
      'revision': 1,
      'objects': entries.map((entry) => entry.toJson()).toList(),
    };
    final rootBytes = canonicalSyncJson(header).length + 28;
    final last = entries.last;
    entries[1023] = SyncRootEntry(
      kind: last.kind,
      id: last.id,
      sha256: last.sha256,
      bytes: last.bytes - rootBytes,
    );
    expect(root(entries).entries.length, 1024);
    entries[1023] = SyncRootEntry(
      kind: last.kind,
      id: last.id,
      sha256: last.sha256,
      bytes: last.bytes - rootBytes + 1,
    );
    expect(() => root(entries), invalid);
  });

  test(
    'software aggregate budget rejects individually valid overfull path lists',
    () {
      final value = card();
      final fields = value['card']! as Map<String, Object?>;
      final paths = List.generate(
        16,
        (i) => '/${'a' * 1018}${i.toString().padLeft(4, '0')}',
      );
      fields['dataPaths'] = paths;
      fields['configPaths'] = paths;
      expect(() => PortableSyncCard.parse(value), invalid);
    },
  );

  test('strict JSON rejects duplicates including escaped aliases, floats and bad Unicode', () {
    for (final body in [
      '{"a":1,"a":2}',
      '{"a":1,"\\u0061":2}',
      '[1.0]',
      '[1e2]',
      'NaN',
      '[9007199254740992]',
      '[01]',
      '[true,]',
      '{"x":"\\ud800"}',
      '\ufeff{}',
      '[{"x":1,"x":2}]',
    ]) {
      expect(
        () => strictSyncJson(
          Uint8List.fromList(utf8.encode(body)),
          maxBytes: 2048,
        ),
        invalid,
        reason: body,
      );
    }
    expect(
      strictSyncJson(
        Uint8List.fromList(utf8.encode('{"valid":[1,true,null]}')),
        maxBytes: 2048,
      ),
      {
        'valid': [1, true, null],
      },
    );
    expect(
      () => strictSyncJson(Uint8List.fromList([0xff]), maxBytes: 10),
      invalid,
    );
    expect(() => strictSyncJson(Uint8List(11), maxBytes: 10), invalid);
  });

  test('canonical codec sorts ASCII keys, preserves Unicode and rejects noncanonical plaintext', () {
    final bytes = canonicalSyncJson({
      'z': ['Привет', 2],
      'a': {'y': true, 'x': null},
    });
    expect(utf8.decode(bytes), '{"a":{"x":null,"y":true},"z":["Привет",2]}');
    expect(
      () => strictSyncJson(
        Uint8List.fromList(utf8.encode('{"b":1,"a":2}')),
        maxBytes: 100,
        canonical: true,
      ),
      invalid,
    );
    expect(() => canonicalSyncJson({'x': 1.0}), invalid);
    expect(() => canonicalSyncJson({'x': '\ud800'}), invalid);
  });

  test('profile preserves raw secret and original target spelling with recomputed endpoint', () {
    final value = PortableSyncProfile.parse(profile());
    expect(value.fields.normalizedHost, 'example.test');
    expect(value.fields.originalHost, 'EXAMPLE.test.');
    expect(utf8.decode(value.copyOriginal()), ' synthetic\n');
    expect(value.toJson(), profile());
    value.dispose();
    expect(() => value.copyOriginal(), invalid);
  });

  test('excluded fields, wrong schema/types, unknown version and noncanonical base64 reject', () {
    final examples = <Map<String, Object?>>[];
    examples.add(profile()..['protectedBytes'] = [1]);
    expect(
      () => PortableSyncProfile.parse(profile()..['version'] = 2),
      throwsA(isA<SyncUnsupportedContentVersion>()),
    );
    final wrongPort = profile();
    (wrongPort['profile'] as Map)['port'] = true;
    examples.add(wrongPort);
    final passphrase = profile();
    (passphrase['credential'] as Map)['passphrase'] = 'must not transfer';
    examples.add(passphrase);
    final metadata = profile();
    (metadata['credential'] as Map)['publicKeyBits'] = 256;
    examples.add(metadata);
    final bad64 = profile();
    (bad64['credential'] as Map)['originalBase64'] = 'YQ';
    examples.add(bad64);
    for (final value in examples) {
      expect(() => PortableSyncProfile.parse(value), invalid);
    }
  });

  test('password UTF8 boundary and invalid encoding never truncate', () {
    final exact = profile();
    (exact['credential'] as Map)['originalBase64'] = base64.encode(
      Uint8List(65536)..fillRange(0, 65536, 65),
    );
    final value = PortableSyncProfile.parse(exact);
    expect(value.copyOriginal().length, 65536);
    value.dispose();
    (exact['credential'] as Map)['originalBase64'] = base64.encode(
      Uint8List(65537),
    );
    expect(() => PortableSyncProfile.parse(exact), invalid);
    (exact['credential'] as Map)['originalBase64'] = base64.encode([0xff]);
    expect(() => PortableSyncProfile.parse(exact), invalid);
  });

  test(
    'leading UTF8 BOM in password is preserved as actual credential data',
    () {
      final data = profile();
      (data['credential'] as Map)['originalBase64'] = base64.encode(
        utf8.encode('\ufeff'),
      );
      final value = PortableSyncProfile.parse(data);
      final bytes = value.copyOriginal();
      expect(decodeSyncUtf8Exact(bytes), '\ufeff');
      expect(bytes, [0xef, 0xbb, 0xbf]);
      value.dispose();
    },
  );

  test('software historical target is valid but its endpoint and field bounds are checked', () {
    final value = PortableSyncCard.parse(card());
    expect(value.profileId, id(10));
    expect(value.card['host'], 'old.example.test');
    final mismatch = card();
    (mismatch['card'] as Map)['endpointId'] = 'a' * 64;
    expect(() => PortableSyncCard.parse(mismatch), invalid);
    final paths = card();
    (paths['card'] as Map)['dataPaths'] = ['relative'];
    expect(() => PortableSyncCard.parse(paths), invalid);
    final leaked = card();
    (leaked['card'] as Map)['revision'] = 1;
    expect(() => PortableSyncCard.parse(leaked), invalid);
  });

  test(
    'root public projection sorts by hash independently of kind/id order',
    () {
      final p = PortableSyncProfile.parse(profile()),
          c = PortableSyncCard.parse(card());
      final entries = [ref(p, 2), ref(c, 1)];
      final validated = root(entries);
      final index = SyncContentIndex()
        ..add(p, expected: entries[0])
        ..add(c, expected: entries[1]);
      index.finish(validated);
      expect(validated.entries.first.kind, 'profile');
      p.dispose();
      expect(() => root(entries.reversed.toList()), invalid);
      expect(
        () => root([
          entries[0],
          SyncRootEntry(
            kind: 'software',
            id: id(20),
            sha256: entries[0].sha256,
            bytes: 2,
          ),
        ]),
        invalid,
      );
    },
  );

  test(
    'index rejects duplicate identities, credential reuse and orphan cards',
    () {
      final p = PortableSyncProfile.parse(profile()),
          duplicate = PortableSyncProfile.parse(
            profile(number: 12, credential: 11),
          );
      final first = ref(p, 1), second = ref(duplicate, 2);
      final index = SyncContentIndex()..add(p, expected: first);
      expect(() => index.add(p, expected: first), invalid);
      expect(() => index.add(duplicate, expected: second), invalid);
      final orphan = PortableSyncCard.parse(card(owner: 90));
      final orphanRef = ref(orphan, 3);
      final orphanIndex = SyncContentIndex()..add(orphan, expected: orphanRef);
      expect(() => orphanIndex.finish(root([orphanRef])), invalid);
      p.dispose();
      duplicate.dispose();
    },
  );

  test('root-entry substitution and incomplete content set cannot finish', () {
    final p = PortableSyncProfile.parse(profile());
    final entry = ref(p, 1);
    final index = SyncContentIndex();
    expect(
      () => index.add(
        p,
        expected: SyncRootEntry(
          kind: 'profile',
          id: id(99),
          sha256: entry.sha256,
          bytes: entry.bytes,
        ),
      ),
      invalid,
    );
    expect(() => index.finish(root([entry])), invalid);
    p.dispose();
  });

  test('per-profile card count is bounded without retaining card payloads', () {
    final p = PortableSyncProfile.parse(profile());
    final index = SyncContentIndex()..add(p, expected: ref(p, 1));
    for (var number = 0; number < 1000; number++) {
      final c = PortableSyncCard.parse(card(number: number + 100));
      index.add(c, expected: ref(c, number + 2));
    }
    final extra = PortableSyncCard.parse(card(number: 2000));
    expect(() => index.add(extra, expected: ref(extra, 2000)), invalid);
    p.dispose();
  });
}
