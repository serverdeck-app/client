import 'dart:convert';
import 'dart:typed_data';

import '../domain/models.dart';
import '../profiles/key_envelope.dart';
import '../profiles/key_parse_worker.dart';
import '../profiles/legacy_pem.dart';
import '../runtime/owned_work.dart';
import '../runtime/platform_ports.dart';
import '../storage/domain_repository.dart';
import '../storage/records.dart';
import 'sync_crypto.dart';
import 'sync_json.dart';
import 'sync_models.dart';
import 'sync_recovery.dart';

const _invalidTransfer = OperationFailure(FailureCode.invalidArgument);
const _staleTransfer = OperationFailure(FailureCode.conflict);
const _badStoredCredential = OperationFailure(FailureCode.storageUnavailable);
const _badKey = OperationFailure(
  FailureCode.unsupportedKey,
  field: OperationField.authentication,
);

enum SyncCredentialProof {
  password,
  validatedPrivateKey,
  encryptedPublicEnvelope,
  encryptedLegacyMetadataOnly,
}

final class SyncTransferSnapshot {
  const SyncTransferSnapshot._(
    this.context,
    this.dataRevision,
    this.syncGeneration,
  );
  final SyncVaultContext context;
  final int dataRevision, syncGeneration;
}

/// Owned prepared local secret only, never a PublicValue or source of SSH grants.
final class SyncPreparedCredential {
  SyncPreparedCredential._(
    this.profileId,
    this.credentialId,
    this.kind,
    this.inspection,
    this.proof,
    this._bytes,
    this._guard,
  );
  final String profileId, credentialId, kind;
  final KeyInspection? inspection;
  final SyncCredentialProof proof;
  final Uint8List _bytes;
  final void Function() _guard;
  bool _disposed = false;
  Uint8List get protectedBytes {
    if (_disposed) throw _invalidTransfer;
    _guard();
    return _bytes.asUnmodifiableView();
  }

  Credential copyRecord({required int secretRevision}) {
    if (secretRevision < 1 || secretRevision > syncMaxInteger)
      throw _invalidTransfer;
    return Credential()
      ..profileId = profileId
      ..credentialId = credentialId
      ..kind = kind
      ..protectedBytes = [...protectedBytes]
      ..publicKeyType = inspection?.keyType
      ..publicKeyBits = inspection?.bits
      ..publicKeyBytes = inspection == null
          ? null
          : [...inspection!.publicKeyBytes]
      ..secretRevision = secretRevision;
  }

  void dispose() {
    _bytes.fillRange(0, _bytes.length, 0);
    _disposed = true;
  }

  @override
  String toString() => 'SyncPreparedCredential(redacted)';
}

final class SyncExportedProfile {
  SyncExportedProfile._(this.entry, this.proof, this._bytes, this._guard);
  final SyncRootEntry entry;
  final SyncCredentialProof proof;
  final Uint8List _bytes;
  final void Function() _guard;
  bool _disposed = false;
  Uint8List get ciphertext {
    if (_disposed) throw _invalidTransfer;
    _guard();
    return _bytes.asUnmodifiableView();
  }

  void dispose() {
    _bytes.fillRange(0, _bytes.length, 0);
    _disposed = true;
  }
}

/// One bounded object at a time. This preparation boundary never writes domain,
/// connects/signs, creates grants, calls public CRUD, or holds a vault snapshot.
/// Full candidate/close/atomic apply lives in sync_atomic_apply.dart.
final class SyncCredentialTransfer {
  SyncCredentialTransfer({
    required this.repository,
    required this.secrets,
    required this.inspector,
    required this.access,
  });
  final DomainRepository repository;
  final PlatformSecretPort secrets;
  final KeyInspector inspector;
  final SyncVaultAccess access;
  bool _busy = false;

  SyncTransferSnapshot capture(SyncVaultContext context) {
    access.guardVaultContext(context);
    return repository.read((r) {
      if (!context.fence.matches(r.syncState)) throw _staleTransfer;
      final data = r.settings.dataRevision,
          generation = r.syncState.syncGeneration;
      if (data < 1 ||
          data > syncMaxInteger ||
          generation < 0 ||
          generation > syncMaxInteger)
        throw _badStoredCredential;
      return SyncTransferSnapshot._(context, data, generation);
    });
  }

  void _guard(SyncTransferSnapshot snapshot, WorkCancellation cancellation) {
    cancellation.check();
    access.guardVaultContext(snapshot.context);
    if (!repository.read(
      (r) =>
          snapshot.context.fence.matches(r.syncState) &&
          r.settings.dataRevision == snapshot.dataRevision &&
          r.syncState.syncGeneration == snapshot.syncGeneration,
    ))
      throw _staleTransfer;
  }

  Future<T> _single<T>(
    SyncTransferSnapshot snapshot,
    WorkCancellation cancellation,
    Future<T> Function() operation,
  ) async {
    _guard(snapshot, cancellation);
    if (_busy)
      throw const OperationFailure(
        FailureCode.resourceExhausted,
        retryable: true,
      );
    _busy = true;
    try {
      return await operation();
    } finally {
      _busy = false;
    }
  }

  void _boundedOriginal(Uint8List bytes, String kind) {
    if (!{'password', 'privateKey'}.contains(kind) ||
        bytes.isEmpty ||
        bytes.length > (kind == 'password' ? 65536 : 1024 * 1024))
      throw _invalidTransfer;
  }

  Future<(KeyInspection?, SyncCredentialProof)> _validate(
    SyncTransferSnapshot snapshot,
    WorkCancellation cancellation,
    PortableSyncProfile profile,
    Uint8List original,
  ) async {
    _guard(snapshot, cancellation);
    _boundedOriginal(original, profile.credentialKind);
    if (profile.credentialKind == 'password') {
      final password = PasswordInput(decodeSyncUtf8Exact(original));
      password.dispose();
      return (null, SyncCredentialProof.password);
    }
    final public = profile.copyPublicKey();
    if (public == null) throw _badKey;
    try {
      final hint = readPublicKeyHint(original, publicKeyBytes: public),
          inspection = hint.inspection;
      if (inspection.keyType != profile.publicKeyType ||
          inspection.bits != profile.publicKeyBits)
        throw _badKey;
      if (!inspection.encrypted) {
        final checked = await inspector.inspect(
          original,
          cancellation: cancellation,
        );
        _guard(snapshot, cancellation);
        if (checked.encrypted ||
            checked.keyType != inspection.keyType ||
            checked.bits != inspection.bits ||
            !sameKeyBytes(checked.publicKeyBytes, hint.encoded))
          throw _badKey;
        return (inspection, SyncCredentialProof.validatedPrivateKey);
      }
      return (
        inspection,
        LegacyPem.recognizes(original)
            ? SyncCredentialProof.encryptedLegacyMetadataOnly
            : SyncCredentialProof.encryptedPublicEnvelope,
      );
    } on OperationFailure {
      rethrow;
    } on WorkCancelled {
      rethrow;
    } catch (_) {
      throw _badKey;
    } finally {
      public.fillRange(0, public.length, 0);
    }
  }

  /// Synchronous private callback only; content is disposed before returning.
  Future<T> withExportedProfile<T>(
    SyncTransferSnapshot snapshot,
    String profileId,
    T Function(PortableSyncProfile profile, SyncCredentialProof proof) use, {
    required WorkCancellation cancellation,
  }) => _single(snapshot, cancellation, () async {
    if (!isCanonicalUuid(profileId)) throw _invalidTransfer;
    final (profile, credential) = repository.read((r) {
      final profile = r.profile(profileId);
      if (profile == null)
        throw const OperationFailure(
          FailureCode.profileNotFound,
          field: OperationField.profileId,
        );
      final credential = r.credential(profile.credentialId);
      if (credential == null ||
          credential.profileId != profileId ||
          credential.credentialId != profile.credentialId ||
          credential.kind != profile.authKind ||
          credential.protectedBytes.isEmpty ||
          credential.protectedBytes.length > syncMaxRootBytes ||
          credential.protectedBytes.any((byte) => byte < 0 || byte > 255))
        throw _badStoredCredential;
      return (profile, credential);
    });
    final protected = Uint8List.fromList(credential.protectedBytes);
    Uint8List? original;
    PortableSyncProfile? content;
    try {
      try {
        original = await secrets.unprotect(
          protected,
          'credential.v1:${credential.credentialId}',
        );
      } catch (_) {
        throw const OperationFailure(FailureCode.protectionUnavailable);
      }
      _guard(snapshot, cancellation);
      _boundedOriginal(original, credential.kind);
      content = PortableSyncProfile.parse({
        'kind': 'profile',
        'version': 1,
        'profile': {
          'profileId': profile.profileId,
          'displayName': profile.displayName,
          'originalHost': profile.originalHost,
          'port': profile.port,
          'username': profile.username,
          'createdAt': profile.createdAt,
          'updatedAt': profile.updatedAt,
        },
        'credential': {
          'credentialId': credential.credentialId,
          'kind': credential.kind,
          'originalBase64': base64.encode(original),
          'publicKeyType': credential.publicKeyType,
          'publicKeyBits': credential.publicKeyBits,
          'publicKeyBase64': credential.publicKeyBytes == null
              ? null
              : base64.encode(credential.publicKeyBytes!),
        },
      });
      if (content.fields.normalizedHost != profile.normalizedHost ||
          content.fields.endpointId != profile.endpointId)
        throw _badStoredCredential;
      final (_, proof) = await _validate(
        snapshot,
        cancellation,
        content,
        original,
      );
      _guard(snapshot, cancellation);
      final result = use(content, proof);
      if (result is Future) throw _invalidTransfer;
      _guard(snapshot, cancellation);
      return result;
    } finally {
      original?.fillRange(0, original.length, 0);
      protected.fillRange(0, protected.length, 0);
      content?.dispose();
    }
  });

  Future<SyncExportedProfile> exportEncryptedProfile(
    SyncTransferSnapshot snapshot,
    String profileId,
    SyncCrypto crypto, {
    required WorkCancellation cancellation,
  }) {
    final expected = snapshot.context.fence.identity, actual = crypto.identity;
    if (expected.serviceOrigin != actual.serviceOrigin ||
        expected.accountId != actual.accountId ||
        expected.vaultId != actual.vaultId ||
        expected.deviceId != actual.deviceId)
      return Future.error(_staleTransfer);
    return withExportedProfile(snapshot, profileId, (profile, proof) {
      final encrypted = crypto.encryptContent(profile);
      return SyncExportedProfile._(
        SyncRootEntry(
          kind: 'profile',
          id: profile.id,
          sha256: syncSha256(encrypted),
          bytes: encrypted.length,
        ),
        proof,
        encrypted,
        () => _guard(snapshot, cancellation),
      );
    }, cancellation: cancellation);
  }

  /// Caller must authenticate the enclosing candidate first; preparation grants
  /// no authority to apply a profile and never accepts/transfers a passphrase.
  Future<SyncPreparedCredential> prepareImported(
    SyncTransferSnapshot snapshot,
    PortableSyncProfile profile, {
    required WorkCancellation cancellation,
  }) => _single(snapshot, cancellation, () async {
    final original = profile.copyOriginal();
    Uint8List? protected;
    try {
      final (inspection, proof) = await _validate(
        snapshot,
        cancellation,
        profile,
        original,
      );
      _guard(snapshot, cancellation);
      try {
        protected = await secrets.protect(
          original,
          'credential.v1:${profile.credentialId}',
        );
        if (protected.isEmpty || protected.length > syncMaxRootBytes)
          throw const OperationFailure(FailureCode.protectionUnavailable);
      } catch (_) {
        throw const OperationFailure(FailureCode.protectionUnavailable);
      }
      _guard(snapshot, cancellation);
      return SyncPreparedCredential._(
        profile.id,
        profile.credentialId,
        profile.credentialKind,
        inspection,
        proof,
        Uint8List.fromList(protected),
        () => _guard(snapshot, cancellation),
      );
    } finally {
      original.fillRange(0, original.length, 0);
      protected?.fillRange(0, protected.length, 0);
    }
  });
}
