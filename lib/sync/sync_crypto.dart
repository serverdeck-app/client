import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../domain/models.dart';
import 'sync_json.dart';
import 'sync_models.dart';

const _invalid = OperationFailure(FailureCode.invalidArgument);

/// Validates the already ordered, opaque public projection. Never sorts received
/// headers: their exact order is authenticated by the root's AAD.
String syncRefsHash(List<SyncBlobRef> objects) {
  if (objects.length > 11000) throw _invalid;
  String? previous;
  var bytes = 0;
  for (final object in objects) {
    if (previous != null && previous.compareTo(object.sha256) >= 0)
      throw _invalid;
    previous = object.sha256;
    bytes += object.bytes;
    if (bytes > syncMaxHeadBytes) throw _invalid;
  }
  return syncSha256(
    canonicalSyncJson(
      objects.map((ref) => {'sha256': ref.sha256, 'bytes': ref.bytes}).toList(),
    ),
  );
}

Uint8List syncObjectAad(SyncIdentity identity, String kind, String id) {
  _objectIdentity(kind, id);
  return canonicalSyncJson({
    'accountId': identity.accountId,
    'vaultId': identity.vaultId,
    'version': 1,
    'contentVersion': 1,
    'kind': kind,
    'id': id,
  });
}

Uint8List syncRootAad(
  SyncIdentity identity,
  String snapshotId,
  int revision,
  List<SyncBlobRef> objects,
) {
  if (!isCanonicalUuid(snapshotId) || revision < 1 || revision > syncMaxInteger)
    throw _invalid;
  return canonicalSyncJson({
    'accountId': identity.accountId,
    'vaultId': identity.vaultId,
    'version': 1,
    'contentVersion': 1,
    'snapshotId': snapshotId,
    'revision': revision,
    'refsHash': syncRefsHash(objects),
  });
}

void _objectIdentity(String kind, String id) {
  if (!{'profile', 'software'}.contains(kind) || !isCanonicalUuid(id))
    throw _invalid;
}

final class SyncEncryptedRoot {
  SyncEncryptedRoot._(this.root, this.envelope, this.ref, this.objects);
  final PortableSyncRoot root;
  final Uint8List envelope;
  final SyncBlobRef ref;
  final List<SyncBlobRef> objects;
}

/// Private native crypto owner. Owns a copy of K until dispose; never sends K or
/// plaintext to storage/transport/logging. Caller owns content and returned key
/// buffers; derived keys returned explicitly must be wiped by their caller.
/// One plaintext object/root at a time, no complete vault plaintext collection.
final class SyncCrypto {
  SyncCrypto({
    required this.identity,
    required Uint8List rootKey,
    Uint8List Function(int)? randomBytes,
  }) : _key = _copyKey(rootKey),
       _randomBytes = randomBytes ?? _secureBytes;
  final SyncIdentity identity;
  final Uint8List _key;
  final Uint8List Function(int) _randomBytes;
  bool _disposed = false;

  static Uint8List _copyKey(Uint8List key) {
    if (key.length != 32) throw _invalid;
    return Uint8List.fromList(key);
  }

  static Uint8List _secureBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  void dispose() {
    _key.fillRange(0, _key.length, 0);
    _disposed = true;
  }

  void _live() {
    if (_disposed) throw _invalid;
  }

  Uint8List _derive(String info) {
    _live();
    final result = Uint8List(32);
    try {
      final hkdf = HKDFKeyDerivator(SHA256Digest())
        ..init(
          HkdfParameters(
            _key,
            32,
            Uint8List.fromList(utf8.encode(identity.vaultId)),
            Uint8List.fromList(utf8.encode(info)),
          ),
        );
      hkdf.deriveKey(null, 0, result, 0);
      return result;
    } catch (_) {
      result.fillRange(0, result.length, 0);
      throw _invalid;
    }
  }

  Uint8List deriveRootKey(String snapshotId) {
    if (!isCanonicalUuid(snapshotId)) throw _invalid;
    return _derive('SD-SYNC/1/root/$snapshotId');
  }

  Uint8List deriveObjectKey(String kind, String id) {
    _objectIdentity(kind, id);
    return _derive('SD-SYNC/1/object/$kind/$id');
  }

  Uint8List encryptContent(PortableSyncContent content) {
    _live();
    final plaintext = canonicalSyncJson(content.toJson());
    try {
      return _encrypt(
        plaintext,
        deriveObjectKey(content.kind, content.id),
        syncObjectAad(identity, content.kind, content.id),
        syncMaxObjectBytes,
      );
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  PortableSyncContent decryptContent({
    required Uint8List envelope,
    required SyncRootEntry expected,
  }) {
    _live();
    _verifyEnvelope(
      envelope,
      SyncBlobRef(expected.sha256, expected.bytes),
      syncMaxObjectBytes,
    );
    final plaintext = _decrypt(
      envelope,
      deriveObjectKey(expected.kind, expected.id),
      syncObjectAad(identity, expected.kind, expected.id),
    );
    try {
      final content = decodeSyncContent(plaintext);
      if (content.kind != expected.kind || content.id != expected.id) {
        content.dispose();
        throw _invalid;
      }
      return content;
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  SyncEncryptedRoot encryptRoot({
    required String snapshotId,
    required int revision,
    required List<SyncRootEntry> entries,
  }) {
    _live();
    if (entries.length > 11000) throw _invalid;
    final sorted = List<SyncRootEntry>.of(entries)
      ..sort((a, b) => a.sha256.compareTo(b.sha256));
    final objects = List<SyncBlobRef>.unmodifiable(
      sorted.map((e) => SyncBlobRef(e.sha256, e.bytes)),
    );
    final aad = syncRootAad(identity, snapshotId, revision, objects);
    final data = <String, Object?>{
      'version': 1,
      'accountId': identity.accountId,
      'vaultId': identity.vaultId,
      'snapshotId': snapshotId,
      'revision': revision,
      'objects': entries.map((e) => e.toJson()).toList(),
    };
    final plaintext = canonicalSyncJson(data);
    Uint8List? envelope;
    var retained = false;
    try {
      envelope = _encrypt(
        plaintext,
        deriveRootKey(snapshotId),
        aad,
        syncMaxRootBytes,
      );
      final ref = SyncBlobRef(syncSha256(envelope), envelope.length);
      final root = PortableSyncRoot.parse(
        data,
        identity: identity,
        snapshotId: snapshotId,
        revision: revision,
        publicObjects: objects,
        publicRoot: ref,
      );
      retained = true;
      return SyncEncryptedRoot._(root, envelope, ref, objects);
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
      if (!retained && envelope != null)
        envelope.fillRange(0, envelope.length, 0);
    }
  }

  PortableSyncRoot decryptRoot({
    required Uint8List envelope,
    required SyncBlobRef root,
    required List<SyncBlobRef> objects,
    required String snapshotId,
    required int revision,
  }) {
    _live();
    _verifyEnvelope(envelope, root, syncMaxRootBytes);
    // Construct/check untrusted AAD before allocating any derived secret key.
    final aad = syncRootAad(identity, snapshotId, revision, objects);
    final plaintext = _decrypt(envelope, deriveRootKey(snapshotId), aad);
    try {
      return PortableSyncRoot.parse(
        strictSyncJson(
          plaintext,
          maxBytes: syncMaxRootBytes - 28,
          canonical: true,
        ),
        identity: identity,
        snapshotId: snapshotId,
        revision: revision,
        publicObjects: objects,
        publicRoot: root,
      );
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  static void _verifyEnvelope(
    Uint8List envelope,
    SyncBlobRef ref,
    int maximum,
  ) {
    if (envelope.length < 28 ||
        envelope.length > maximum ||
        envelope.length != ref.bytes ||
        syncSha256(envelope) != ref.sha256)
      throw _invalid;
  }

  Uint8List _encrypt(
    Uint8List plaintext,
    Uint8List key,
    Uint8List aad,
    int maximum,
  ) {
    Uint8List? output;
    var retained = false;
    try {
      if (plaintext.length + 28 > maximum) throw _invalid;
      final nonce = _randomBytes(12);
      if (nonce.length != 12) throw _invalid;
      final cipher = GCMBlockCipher(AESEngine())
        ..init(true, AEADParameters(KeyParameter(key), 128, nonce, aad));
      // Allocate our own output so failures cannot strand an owned buffer.
      output = Uint8List(cipher.getOutputSize(plaintext.length) + 12);
      output.setRange(0, 12, nonce);
      var written = cipher.processBytes(
        plaintext,
        0,
        plaintext.length,
        output,
        12,
      );
      written += cipher.doFinal(output, 12 + written);
      if (written != plaintext.length + 16) throw _invalid;
      retained = true;
      return Uint8List.sublistView(output, 0, written + 12);
    } catch (_) {
      throw _invalid;
    } finally {
      key.fillRange(0, key.length, 0);
      if (!retained && output != null) output.fillRange(0, output.length, 0);
    }
  }

  static Uint8List _decrypt(Uint8List envelope, Uint8List key, Uint8List aad) {
    Uint8List? output;
    var retained = false;
    try {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(key),
            128,
            Uint8List.sublistView(envelope, 0, 12),
            aad,
          ),
        );
      output = Uint8List(cipher.getOutputSize(envelope.length - 12));
      var written = cipher.processBytes(
        envelope,
        12,
        envelope.length - 12,
        output,
        0,
      );
      written += cipher.doFinal(
        output,
        written,
      ); // Authenticate before parsing/return.
      if (written != envelope.length - 28) throw _invalid;
      retained = true;
      return Uint8List.sublistView(output, 0, written);
    } catch (_) {
      throw _invalid;
    } finally {
      key.fillRange(0, key.length, 0);
      if (!retained && output != null) output.fillRange(0, output.length, 0);
    }
  }
}
