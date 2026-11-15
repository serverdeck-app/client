import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

import '../domain/models.dart';
import '../profiles/credential_input.dart' show normalizeHost;
import '../profiles/credential_input.dart'
    show ValidatedProfileFields, validateProfileValues;
import '../profiles/key_envelope.dart' show PublicKeyHint;
import '../software/software_models.dart';
import '../storage/records.dart';
import 'sync_json.dart';

const syncMaxInteger = 9007199254740991;
const syncMaxObjectBytes = 4 * 1024 * 1024;
const syncMaxRootBytes = 2 * 1024 * 1024;
const syncMaxHeadBytes = 4 * 1024 * 1024 * 1024;
const syncMaxWorkingBytes = 24 * 1024 * 1024 * 1024;
const syncMinFreeBytes = 256 * 1024 * 1024;

String syncSha256(List<int> bytes) => SHA256Digest()
    .process(bytes is Uint8List ? bytes : Uint8List.fromList(bytes))
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

bool isSyncHash(String value) =>
    value.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

/// Host spelling shared by user origin normalization and durable bindings.
/// Prevent legacy numeric authorities that browsers can reinterpret as IPv4.
String normalizeSyncHost(String input) {
  final original = input.endsWith('.')
      ? input.substring(0, input.length - 1)
      : input;
  if (original.endsWith('.'))
    throw const OperationFailure(FailureCode.invalidArgument);
  final host = normalizeHost(original);
  final numericLast = RegExp(r'^(?:[0-9]+|0[xX][0-9a-fA-F]*)$')
      .hasMatch(host.split('.').last);
  if (numericLast) {
    final parts = host.split('.');
    if (parts.length != 4 ||
        original != host ||
        parts.any(
          (part) =>
              !RegExp(r'^(?:0|[1-9][0-9]{0,2})$').hasMatch(part) ||
              int.parse(part) > 255,
        )) {
      throw const OperationFailure(FailureCode.invalidArgument);
    }
  }
  return host;
}

/// Private canonical binding, not the user-input origin normalization UI.
/// Unicode origins must first be normalized by the pure account setting boundary.
final class SyncIdentity {
  SyncIdentity({
    required this.serviceOrigin,
    required this.accountId,
    required this.deviceId,
    required this.vaultId,
  }) {
    const failure = OperationFailure(FailureCode.invalidArgument);
    if (![accountId, deviceId, vaultId].every(isCanonicalUuid) ||
        serviceOrigin.length > 512 ||
        RegExp(r'[^\x21-\x7e]').hasMatch(serviceOrigin))
      throw failure;
    try {
      final uri = Uri.parse(serviceOrigin);
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.path.isNotEmpty ||
          uri.port < 1 ||
          uri.port > 65535)
        throw failure;
      final host = normalizeSyncHost(uri.host);
      final normalized = Uri(
        scheme: 'https',
        host: host,
        port: uri.port == 443 ? null : uri.port,
      ).origin;
      if (normalized != serviceOrigin) throw failure;
    } on FormatException {
      throw failure;
    }
  }
  final String serviceOrigin, accountId, deviceId, vaultId;
  bool matches(SyncStateRecord state) =>
      state.serviceOrigin == serviceOrigin &&
      state.accountId == accountId &&
      state.deviceId == deviceId &&
      state.vaultId == vaultId;
  bool owns(SyncRootRecord root) =>
      root.serviceOrigin == serviceOrigin &&
      root.accountId == accountId &&
      root.vaultId == vaultId;
  String objectKey(String hash) {
    if (!isSyncHash(hash))
      throw const OperationFailure(FailureCode.invalidArgument);
    return syncSha256(
      utf8.encode(jsonEncode([serviceOrigin, accountId, vaultId, hash])),
    );
  }
}

final class SyncFence {
  const SyncFence(this.identity, this.generation);
  final SyncIdentity identity;
  final int generation;
  bool matches(SyncStateRecord state) =>
      state.enabled &&
      state.identityGeneration == generation &&
      identity.matches(state);
}

final class SyncBlobRef {
  SyncBlobRef(this.sha256, this.bytes) {
    if (!isSyncHash(sha256) || bytes < 1 || bytes > syncMaxObjectBytes) {
      throw const OperationFailure(FailureCode.invalidArgument);
    }
  }
  final String sha256;
  final int bytes;
}

const _contentInvalid = OperationFailure(FailureCode.invalidArgument);
const _contentLimit = OperationFailure(FailureCode.resourceExhausted);

final class SyncUnsupportedContentVersion implements Exception {
  const SyncUnsupportedContentVersion();
  @override
  String toString() => 'UNSUPPORTED_CONTENT_VERSION';
}

Map<String, Object?> _exact(Object? value, Set<String> fields) {
  if (value is! Map<String, Object?> ||
      value.length != fields.length ||
      !value.keys.every(fields.contains))
    throw _contentInvalid;
  return value;
}

String _text(Object? value) {
  if (value is! String || !isWellFormedUnicode(value)) throw _contentInvalid;
  return value;
}

String _uuid(Object? value) {
  final result = _text(value);
  if (!isCanonicalUuid(result)) throw _contentInvalid;
  return result;
}

int _integer(
  Object? value, {
  int minimum = -syncMaxInteger,
  int maximum = syncMaxInteger,
}) {
  if (value is! int || value < minimum || value > maximum)
    throw _contentInvalid;
  return value;
}

void _version(Object? value) {
  if (_integer(value) != 1) throw const SyncUnsupportedContentVersion();
}

Uint8List _base64(Object? value, int maximum) {
  final source = _text(value);
  if (source.isEmpty) throw _contentInvalid;
  if (source.length > 4 * ((maximum + 2) ~/ 3)) throw _contentLimit;
  try {
    final bytes = base64.decode(source);
    if (bytes.length > maximum) {
      bytes.fillRange(0, bytes.length, 0);
      throw _contentLimit;
    }
    if (bytes.isEmpty || base64.encode(bytes) != source) {
      bytes.fillRange(0, bytes.length, 0);
      throw _contentInvalid;
    }
    return bytes;
  } on OperationFailure {
    rethrow;
  } catch (_) {
    throw _contentInvalid;
  }
}

int _serializedSize(Object? value) {
  final bytes = canonicalSyncJson(value);
  try {
    return bytes.length;
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

/// Structurally checked content only. Key-envelope validation/protection and
/// authenticated root binding remain separate mandatory preparation steps.
sealed class PortableSyncContent {
  String get kind;
  String get id;
  Map<String, Object?> toJson();
  void dispose();
}

PortableSyncContent parseSyncContent(Object? value) {
  if (value is! Map<String, Object?>) throw _contentInvalid;
  return switch (value['kind']) {
    'profile' => PortableSyncProfile.parse(value),
    'software' => PortableSyncCard.parse(value),
    _ => throw _contentInvalid,
  };
}

PortableSyncContent decodeSyncContent(Uint8List plaintext) => parseSyncContent(
  strictSyncJson(plaintext, maxBytes: syncMaxObjectBytes - 28, canonical: true),
);

final class PortableSyncProfile extends PortableSyncContent {
  PortableSyncProfile._(
    this.profile,
    this._credential,
    this.fields,
    this._original,
  );
  final Map<String, Object?> profile;
  final Map<String, Object?> _credential;
  final ValidatedProfileFields fields;
  final Uint8List _original;
  bool _disposed = false;
  @override
  String get kind => 'profile';
  @override
  String get id => profile['profileId']! as String;
  String get credentialId => _credential['credentialId']! as String;
  String get credentialKind => _credential['kind']! as String;
  String? get publicKeyType => _credential['publicKeyType'] as String?;
  int? get publicKeyBits => _credential['publicKeyBits'] as int?;
  Uint8List? copyPublicKey() => _credential['publicKeyBase64'] == null
      ? null
      : base64.decode(_credential['publicKeyBase64']! as String);
  Uint8List copyOriginal() {
    if (_disposed) throw _contentInvalid;
    return Uint8List.fromList(_original);
  }

  @override
  void dispose() {
    _original.fillRange(0, _original.length, 0);
    _disposed = true;
  }

  @override
  Map<String, Object?> toJson() {
    if (_disposed) throw _contentInvalid;
    return {
      'kind': kind,
      'version': 1,
      'profile': profile,
      'credential': {
        ..._credential,
        'originalBase64': base64.encode(_original),
      },
    };
  }

  factory PortableSyncProfile.parse(Object? value) {
    final data = _exact(value, {'kind', 'version', 'profile', 'credential'});
    if (data['kind'] != 'profile') throw _contentInvalid;
    _version(data['version']);
    final p = _exact(data['profile'], {
      'profileId',
      'displayName',
      'originalHost',
      'port',
      'username',
      'createdAt',
      'updatedAt',
    });
    _uuid(p['profileId']);
    final fields = validateProfileValues(
      displayName: _text(p['displayName']),
      host: _text(p['originalHost']),
      port: _integer(p['port'], minimum: 1, maximum: 65535),
      username: _text(p['username']),
    );
    if (fields.displayName != p['displayName']) throw _contentInvalid;
    _integer(p['createdAt']);
    _integer(p['updatedAt']);
    final c = _exact(data['credential'], {
      'credentialId',
      'kind',
      'originalBase64',
      'publicKeyType',
      'publicKeyBits',
      'publicKeyBase64',
    });
    _uuid(c['credentialId']);
    if (c['kind'] != 'password' && c['kind'] != 'privateKey')
      throw _contentInvalid;
    Uint8List? original;
    try {
      original = _base64(
        c['originalBase64'],
        c['kind'] == 'password' ? 65536 : 1024 * 1024,
      );
      if (c['kind'] == 'password') {
        if (c['publicKeyType'] != null ||
            c['publicKeyBits'] != null ||
            c['publicKeyBase64'] != null)
          throw _contentInvalid;
        final password = PasswordInput(decodeSyncUtf8Exact(original));
        password.dispose();
      } else {
        final public = _base64(c['publicKeyBase64'], 256 * 1024);
        final hint = PublicKeyHint.decode(public, encrypted: false);
        if (_text(c['publicKeyType']) != hint.inspection.keyType ||
            _integer(c['publicKeyBits'], minimum: 1) != hint.inspection.bits)
          throw _contentInvalid;
      }
      if (_serializedSize(data) > syncMaxObjectBytes - 28) throw _contentLimit;
      final metadata = Map<String, Object?>.of(c)..remove('originalBase64');
      return PortableSyncProfile._(
        Map.unmodifiable(p),
        Map.unmodifiable(metadata),
        fields,
        original,
      );
    } on OperationFailure {
      original?.fillRange(0, original.length, 0);
      rethrow;
    } catch (_) {
      original?.fillRange(0, original.length, 0);
      throw _contentInvalid;
    }
  }
}

final class PortableSyncCard extends PortableSyncContent {
  PortableSyncCard._(this.card);
  final Map<String, Object?> card;
  @override
  String get kind => 'software';
  @override
  String get id => card['softwareId']! as String;
  String get profileId => card['profileId']! as String;
  @override
  void dispose() {}
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'version': 1, 'card': card};
  factory PortableSyncCard.parse(Object? value) {
    final data = _exact(value, {'kind', 'version', 'card'});
    if (data['kind'] != 'software') throw _contentInvalid;
    _version(data['version']);
    final c = _exact(data['card'], {
      'softwareId',
      'profileId',
      'endpointId',
      'host',
      'port',
      'username',
      'name',
      'version',
      'service',
      'dataPaths',
      'configPaths',
      'createdAt',
      'updatedAt',
    });
    final target = validateProfileValues(
      displayName: 'target',
      host: _text(c['host']),
      port: _integer(c['port'], minimum: 1, maximum: 65535),
      username: _text(c['username']),
    );
    if (_text(c['endpointId']) != target.endpointId ||
        c['host'] != target.normalizedHost)
      throw _contentInvalid;
    List<String> paths(Object? value) {
      if (value is! List || value.length > 16) throw _contentInvalid;
      return value.map(_text).toList();
    }

    final input = SoftwareCardInput(
      name: _text(c['name']),
      version: c['version'] == null ? null : _text(c['version']),
      service: c['service'] == null ? null : _text(c['service']),
      dataPaths: paths(c['dataPaths']),
      configPaths: paths(c['configPaths']),
    );
    if (input.name != c['name'] ||
        input.version != c['version'] ||
        input.service != c['service'])
      throw _contentInvalid;
    final record = SoftwareCardRecord()
      ..softwareId = _uuid(c['softwareId'])
      ..profileId = _uuid(c['profileId'])
      ..endpointId = target.endpointId
      ..host = target.normalizedHost
      ..port = target.port
      ..username = target.username
      ..name = input.name
      ..version = input.version
      ..service = input.service
      ..dataPaths = input.dataPaths
      ..configPaths = input.configPaths
      ..createdAt = _integer(c['createdAt'])
      ..updatedAt = _integer(c['updatedAt']);
    // Structural compatibility uses the same minimum local metadata as create.
    // SyncApply revalidates actual destination counters/target before committing.
    SoftwareCardView(record, currentTarget: true);
    if (_serializedSize(data) > softwareCardBytes) throw _contentLimit;
    return PortableSyncCard._(
      Map.unmodifiable({
        ...c,
        'dataPaths': List<String>.unmodifiable(input.dataPaths),
        'configPaths': List<String>.unmodifiable(input.configPaths),
      }),
    );
  }
}

final class SyncRootEntry {
  SyncRootEntry({
    required this.kind,
    required this.id,
    required this.sha256,
    required this.bytes,
  }) {
    if (!{'profile', 'software'}.contains(kind) || !isCanonicalUuid(id))
      throw _contentInvalid;
    SyncBlobRef(sha256, bytes);
  }
  final String kind, id, sha256;
  final int bytes;
  Map<String, Object?> toJson() => {
    'kind': kind,
    'id': id,
    'sha256': sha256,
    'bytes': bytes,
  };
}

final class PortableSyncRoot {
  PortableSyncRoot._(
    this.accountId,
    this.vaultId,
    this.snapshotId,
    this.revision,
    this.entries,
  );
  final String accountId, vaultId, snapshotId;
  final int revision;
  final List<SyncRootEntry> entries;
  Map<String, Object?> toJson() => {
    'version': 1,
    'accountId': accountId,
    'vaultId': vaultId,
    'snapshotId': snapshotId,
    'revision': revision,
    'objects': entries.map((entry) => entry.toJson()).toList(),
  };
  factory PortableSyncRoot.parse(
    Object? value, {
    required SyncIdentity identity,
    required String snapshotId,
    required int revision,
    required List<SyncBlobRef> publicObjects,
    required SyncBlobRef publicRoot,
  }) {
    final data = _exact(value, {
      'version',
      'accountId',
      'vaultId',
      'snapshotId',
      'revision',
      'objects',
    });
    _version(data['version']);
    if (_uuid(data['accountId']) != identity.accountId ||
        _uuid(data['vaultId']) != identity.vaultId ||
        _uuid(data['snapshotId']) != snapshotId ||
        _integer(data['revision'], minimum: 1) != revision ||
        publicRoot.bytes > syncMaxRootBytes ||
        data['objects'] is! List ||
        (data['objects']! as List).length > 11000)
      throw _contentInvalid;
    final entries = <SyncRootEntry>[];
    final hashes = <String>{};
    var profiles = 0, cards = 0;
    String? previous;
    for (final item in data['objects']! as List) {
      final entry = _exact(item, {'kind', 'id', 'sha256', 'bytes'});
      final ref = SyncRootEntry(
        kind: _text(entry['kind']),
        id: _uuid(entry['id']),
        sha256: _text(entry['sha256']),
        bytes: _integer(
          entry['bytes'],
          minimum: 1,
          maximum: syncMaxObjectBytes,
        ),
      );
      final key = '${ref.kind}/${ref.id}';
      if (previous != null && previous.compareTo(key) >= 0 ||
          !hashes.add(ref.sha256) ||
          ref.sha256 == publicRoot.sha256)
        throw _contentInvalid;
      if (ref.kind == 'profile')
        profiles++;
      else
        cards++;
      previous = key;
      entries.add(ref);
    }
    if (profiles > 1000 ||
        cards > 10000 ||
        entries.fold<int>(publicRoot.bytes, (sum, entry) => sum + entry.bytes) >
            syncMaxHeadBytes)
      throw _contentLimit;
    if (_serializedSize(data) + 28 != publicRoot.bytes) throw _contentInvalid;
    final projection = List<SyncRootEntry>.of(entries)
      ..sort((a, b) => a.sha256.compareTo(b.sha256));
    if (projection.length != publicObjects.length) throw _contentInvalid;
    for (var index = 0; index < projection.length; index++) {
      if (projection[index].sha256 != publicObjects[index].sha256 ||
          projection[index].bytes != publicObjects[index].bytes)
        throw _contentInvalid;
    }
    return PortableSyncRoot._(
      identity.accountId,
      identity.vaultId,
      snapshotId,
      revision,
      List.unmodifiable(entries),
    );
  }
}

/// Streaming semantic index: retains only IDs/counts/ref metadata, never secrets
/// or the complete profile/card plaintext set.
final class SyncContentIndex {
  final _seen = <String, SyncRootEntry>{};
  final _profiles = <String>{}, _credentials = <String>{};
  final _cardsPerProfile = <String, int>{};
  int _cards = 0;
  void add(PortableSyncContent content, {required SyncRootEntry expected}) {
    final key = '${content.kind}/${content.id}';
    if (content.kind != expected.kind ||
        content.id != expected.id ||
        _seen.containsKey(key) ||
        _serializedSize(content.toJson()) + 28 != expected.bytes)
      throw _contentInvalid;
    if (content is PortableSyncProfile) {
      if (_profiles.length >= 1000) throw _contentLimit;
      if (_credentials.contains(content.credentialId)) throw _contentInvalid;
      _profiles.add(content.id);
      _credentials.add(content.credentialId);
    } else if (content is PortableSyncCard) {
      final count = _cardsPerProfile[content.profileId] ?? 0;
      if (_cards >= 10000 || count >= 1000) throw _contentLimit;
      _cards++;
      _cardsPerProfile[content.profileId] = count + 1;
    }
    _seen[key] = expected;
  }

  void finish(PortableSyncRoot root) {
    if (_cardsPerProfile.keys.any((id) => !_profiles.contains(id))) {
      throw const OperationFailure(
        FailureCode.invalidArgument,
        field: OperationField.profileId,
      );
    }
    if (_seen.length != root.entries.length) throw _contentInvalid;
    for (final entry in root.entries) {
      final actual = _seen['${entry.kind}/${entry.id}'];
      if (actual == null ||
          actual.sha256 != entry.sha256 ||
          actual.bytes != entry.bytes)
        throw _contentInvalid;
    }
  }
}
