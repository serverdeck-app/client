import 'dart:convert';

import '../domain/models.dart';
import 'sync_crypto.dart' show syncRefsHash;
import 'sync_json.dart';
import 'sync_models.dart';

const syncInvalidWire = OperationFailure(FailureCode.invalidArgument);

/// Internal consumer validators, not domain/API projections.
abstract final class SyncWire {
  static Map<String, Object?> exact(Object? value, Set<String> fields) {
    if (value is! Map<String, Object?> ||
        value.length != fields.length ||
        !value.keys.every(fields.contains))
      throw syncInvalidWire;
    return value;
  }

  static String text(Object? value, {int max = 512}) {
    if (value is! String ||
        value.isEmpty ||
        value.length > max ||
        !isWellFormedUnicode(value))
      throw syncInvalidWire;
    return value;
  }

  static String uuid(Object? value) {
    final result = text(value, max: 36);
    if (!isCanonicalUuid(result)) throw syncInvalidWire;
    return result;
  }

  static int integer(Object? value, {int min = 0, int max = syncMaxInteger}) {
    if (value is! int || value < min || value > max) throw syncInvalidWire;
    return value;
  }

  static String token(Object? value) {
    final result = text(value, max: 43);
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(result)) throw syncInvalidWire;
    try {
      if (base64Url.encode(base64Url.decode('$result=')).replaceAll('=', '') !=
          result)
        throw syncInvalidWire;
    } catch (_) {
      throw syncInvalidWire;
    }
    return result;
  }

  static String deviceName(Object? value) {
    final name = text(value, max: 200);
    if (name.trim() != name ||
        name.runes.length > 100 ||
        RegExp(r'[\p{Cc}\p{Cf}\p{Cs}]', unicode: true).hasMatch(name))
      throw syncInvalidWire;
    return name;
  }

  static SyncBlobRef blob(Object? value) {
    final map = exact(value, {'sha256', 'bytes'});
    return SyncBlobRef(
      text(map['sha256'], max: 64),
      integer(map['bytes'], min: 1, max: syncMaxObjectBytes),
    );
  }
}

/// Already normalized origin. sync_origin.dart owns Unicode setting/rebind input;
/// transport never mutates this captured value.
final class SyncServiceOrigin {
  SyncServiceOrigin(String value) : value = value {
    const id = '00000000-0000-4000-8000-000000000000';
    SyncIdentity(
      serviceOrigin: value,
      accountId: id,
      deviceId: id,
      vaultId: id,
    );
  }
  final String value;
  Uri resolve(String path, [Map<String, String>? query]) {
    if (!path.startsWith('/v1/') ||
        path.contains('..') ||
        path.contains('?') ||
        path.contains('#'))
      throw syncInvalidWire;
    return Uri.parse(value).replace(path: path, queryParameters: query);
  }
}

enum SyncSecretKind { access, refresh, deviceCode, statusProof }

/// Secrets carry an immutable origin; neither this nor wire responses implement
/// PublicValue or serialize themselves for UI/logging.
final class SyncBoundSecret {
  SyncBoundSecret({
    required this.origin,
    required this.kind,
    required String value,
  }) : value = kind == SyncSecretKind.statusProof
           ? SyncWire.text(value)
           : SyncWire.token(value) {
    if (kind == SyncSecretKind.statusProof &&
        RegExp(r'[^\x21-\x7e]').hasMatch(value))
      throw syncInvalidWire;
  }
  final SyncServiceOrigin origin;
  final SyncSecretKind kind;
  final String value;
}

final class SyncManifest {
  SyncManifest._(
    this.vaultId,
    this.snapshotId,
    this.revision,
    this.objects,
    this.root,
  );
  final String vaultId, snapshotId;
  final int revision;
  final List<SyncBlobRef> objects;
  final SyncBlobRef root;
  Map<String, Object?> toJson() => {
    'version': 1,
    'content_version': 1,
    'vault_id': vaultId,
    'snapshot_id': snapshotId,
    'revision': revision,
    'objects': objects
        .map((ref) => {'sha256': ref.sha256, 'bytes': ref.bytes})
        .toList(),
    'root': {'sha256': root.sha256, 'bytes': root.bytes},
  };
  factory SyncManifest.parse(Object? value) {
    final map = SyncWire.exact(value, {
      'version',
      'content_version',
      'vault_id',
      'snapshot_id',
      'revision',
      'objects',
      'root',
    });
    if (SyncWire.integer(map['version']) != 1 ||
        SyncWire.integer(map['content_version']) != 1)
      throw const SyncUnsupportedContentVersion();
    final vault = SyncWire.uuid(map['vault_id']),
        snapshot = SyncWire.uuid(map['snapshot_id']);
    final revision = SyncWire.integer(map['revision'], min: 1);
    if (map['objects'] is! List || (map['objects']! as List).length > 11000)
      throw syncInvalidWire;
    final objects = (map['objects']! as List)
        .map(SyncWire.blob)
        .toList(growable: false);
    syncRefsHash(objects);
    final root = SyncWire.blob(map['root']);
    if (root.bytes > syncMaxRootBytes ||
        objects.any((ref) => ref.sha256 == root.sha256) ||
        objects.fold(root.bytes, (sum, ref) => sum + ref.bytes) >
            syncMaxHeadBytes)
      throw syncInvalidWire;
    final encoded = canonicalSyncJson(map);
    try {
      if (encoded.length > syncMaxRootBytes) throw syncInvalidWire;
    } finally {
      encoded.fillRange(0, encoded.length, 0);
    }
    return SyncManifest._(
      vault,
      snapshot,
      revision,
      List.unmodifiable(objects),
      root,
    );
  }
}

final class SyncHead {
  SyncHead._(this.vaultId, this.revision, this.manifest);
  final String vaultId;
  final int revision;
  final SyncManifest? manifest;
  factory SyncHead.parse(Object? value, {required String vaultId}) {
    SyncWire.uuid(vaultId);
    final map = SyncWire.exact(value, {'vault_id', 'revision', 'manifest'});
    final revision = SyncWire.integer(map['revision']);
    if (SyncWire.uuid(map['vault_id']) != vaultId) throw syncInvalidWire;
    if (revision == 0) {
      if (map['manifest'] != null) throw syncInvalidWire;
      return SyncHead._(vaultId, 0, null);
    }
    final manifest = SyncManifest.parse(map['manifest']);
    if (manifest.vaultId != vaultId || manifest.revision != revision)
      throw syncInvalidWire;
    return SyncHead._(vaultId, revision, manifest);
  }
}

final class SyncDeviceAuthorization {
  SyncDeviceAuthorization._(
    this.deviceCode,
    this.userCode,
    this.verificationUri,
    this.completeUri,
  );
  final SyncBoundSecret deviceCode;
  final String userCode;
  final Uri verificationUri, completeUri;
  factory SyncDeviceAuthorization.parse(
    Object? value,
    SyncServiceOrigin origin,
  ) {
    final map = SyncWire.exact(value, {
      'device_code',
      'user_code',
      'verification_uri',
      'verification_uri_complete',
      'expires_in',
      'interval',
    });
    if (SyncWire.integer(map['expires_in']) != 600 ||
        SyncWire.integer(map['interval']) != 5)
      throw syncInvalidWire;
    final code = SyncWire.text(map['user_code'], max: 10);
    if (!RegExp(r'^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{10}$').hasMatch(code))
      throw syncInvalidWire;
    final verification = Uri.parse('${origin.value}/activate');
    final complete = verification.replace(queryParameters: {'user_code': code});
    if (map['verification_uri'] != verification.toString() ||
        map['verification_uri_complete'] != complete.toString())
      throw syncInvalidWire;
    return SyncDeviceAuthorization._(
      SyncBoundSecret(
        origin: origin,
        kind: SyncSecretKind.deviceCode,
        value: SyncWire.token(map['device_code']),
      ),
      code,
      verification,
      complete,
    );
  }
}

final class SyncSessionTokens {
  SyncSessionTokens._(this.access, this.refresh);
  final SyncBoundSecret access, refresh;
  factory SyncSessionTokens.parse(Object? value, SyncServiceOrigin origin) {
    final map = SyncWire.exact(value, {
      'access_token',
      'refresh_token',
      'expires_in',
    });
    if (SyncWire.integer(map['expires_in']) != 900) throw syncInvalidWire;
    return SyncSessionTokens._(
      SyncBoundSecret(
        origin: origin,
        kind: SyncSecretKind.access,
        value: SyncWire.token(map['access_token']),
      ),
      SyncBoundSecret(
        origin: origin,
        kind: SyncSecretKind.refresh,
        value: SyncWire.token(map['refresh_token']),
      ),
    );
  }
}

final class SyncNativeSession {
  SyncNativeSession._(
    this.accountId,
    this.deviceId,
    this.vaultId,
    this.email,
    this.tokens,
    this.statusProof,
  );
  final String accountId, deviceId, vaultId, email;
  final SyncSessionTokens tokens;
  final SyncBoundSecret statusProof;
  factory SyncNativeSession.parse(Object? value, SyncServiceOrigin origin) {
    final map = SyncWire.exact(value, {
      'account_id',
      'device_id',
      'vault_id',
      'email',
      'access_token',
      'refresh_token',
      'expires_in',
      'status_proof',
    });
    final email = SyncWire.text(map['email'], max: 254);
    if (RegExp(r'[^\x21-\x7e]').hasMatch(email) ||
        '@'.allMatches(email).length != 1)
      throw syncInvalidWire;
    return SyncNativeSession._(
      SyncWire.uuid(map['account_id']),
      SyncWire.uuid(map['device_id']),
      SyncWire.uuid(map['vault_id']),
      email,
      SyncSessionTokens.parse({
        'access_token': map['access_token'],
        'refresh_token': map['refresh_token'],
        'expires_in': map['expires_in'],
      }, origin),
      SyncBoundSecret(
        origin: origin,
        kind: SyncSecretKind.statusProof,
        value: SyncWire.text(map['status_proof']),
      ),
    );
  }
}

final class SyncUploadDeclaration {
  SyncUploadDeclaration._(this.uploadId, this.expiresAt, this.missing);
  final String uploadId;
  final int expiresAt;
  final List<String> missing;
  factory SyncUploadDeclaration.parse(
    Object? value,
    String uploadId,
    SyncManifest manifest,
  ) {
    final map = SyncWire.exact(value, {'upload_id', 'expires_at', 'missing'});
    if (SyncWire.uuid(map['upload_id']) != uploadId ||
        map['missing'] is! List ||
        (map['missing']! as List).length > manifest.objects.length + 1)
      throw syncInvalidWire;
    final allowed = {
      manifest.root.sha256,
      ...manifest.objects.map((ref) => ref.sha256),
    };
    final seen = <String>{};
    final missing = <String>[];
    for (final item in map['missing']! as List) {
      final hash = SyncWire.text(item, max: 64);
      if (!allowed.contains(hash) || !seen.add(hash)) throw syncInvalidWire;
      missing.add(hash);
    }
    return SyncUploadDeclaration._(
      uploadId,
      SyncWire.integer(map['expires_at']),
      List.unmodifiable(missing),
    );
  }
}

final class SyncCommitReceipt {
  SyncCommitReceipt._(
    this.vaultId,
    this.snapshotId,
    this.commitId,
    this.revision,
  );
  final String vaultId, snapshotId, commitId;
  final int revision;
  factory SyncCommitReceipt.parse(
    Object? value,
    String commitId,
    SyncManifest manifest,
  ) {
    final map = SyncWire.exact(value, {
      'vault_id',
      'revision',
      'snapshot_id',
      'commit_id',
    });
    if (SyncWire.uuid(map['vault_id']) != manifest.vaultId ||
        SyncWire.uuid(map['snapshot_id']) != manifest.snapshotId ||
        SyncWire.uuid(map['commit_id']) != commitId ||
        SyncWire.integer(map['revision'], min: 1) != manifest.revision)
      throw syncInvalidWire;
    return SyncCommitReceipt._(
      manifest.vaultId,
      manifest.snapshotId,
      commitId,
      manifest.revision,
    );
  }
}

final class SyncRemoteDevice {
  SyncRemoteDevice._(this.id, this.name, this.platform, this.lastSeenAt);
  final String id, name, platform;
  final int lastSeenAt;
  factory SyncRemoteDevice.parse(Object? value) {
    final map = SyncWire.exact(value, {
      'id',
      'name',
      'platform',
      'last_seen_at',
    });
    if (map['platform'] != 'windows' && map['platform'] != 'android')
      throw syncInvalidWire;
    return SyncRemoteDevice._(
      SyncWire.uuid(map['id']),
      SyncWire.deviceName(map['name']),
      map['platform']! as String,
      SyncWire.integer(map['last_seen_at']),
    );
  }
}
