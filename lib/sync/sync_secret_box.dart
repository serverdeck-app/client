import 'dart:convert';
import 'dart:typed_data';

import '../domain/models.dart';
import '../runtime/platform_ports.dart';
import 'sync_json.dart';
import 'sync_models.dart';
import 'sync_wire.dart';

enum SyncLocalSecretKind { access, refresh, statusProof, vaultKey }

/// Root-owned local wrapping, not vault content encryption. Domain binding is
/// authenticated by DPAPI entropy / Android GCM purpose AAD, never a mutable URL.
final class SyncSecretBox {
  const SyncSecretBox(this.port);
  final PlatformSecretPort port;
  String purpose(SyncIdentity identity, SyncLocalSecretKind kind) {
    final binding = canonicalSyncJson({
      'origin': identity.serviceOrigin,
      'account': identity.accountId,
      'vault': identity.vaultId,
      // K survives explicit same-account/vault reauthorization on this device.
      if (kind != SyncLocalSecretKind.vaultKey) 'device': identity.deviceId,
    });
    return 'ServerDeck.Sync.1.${kind.name}.${syncSha256(binding)}';
  }

  String _text(String value, SyncLocalSecretKind kind) {
    if (kind == SyncLocalSecretKind.vaultKey) throw syncInvalidWire;
    if (kind != SyncLocalSecretKind.statusProof) return SyncWire.token(value);
    SyncWire.text(value);
    if (RegExp(r'[^\x21-\x7e]').hasMatch(value)) throw syncInvalidWire;
    return value;
  }

  Future<Uint8List> protectText(
    SyncIdentity identity,
    SyncLocalSecretKind kind,
    String value,
  ) async {
    final bytes = Uint8List.fromList(utf8.encode(_text(value, kind)));
    try {
      return await _protect(identity, kind, bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<String> unprotectText(
    SyncIdentity identity,
    SyncLocalSecretKind kind,
    List<int> protected,
  ) async {
    final bytes = await _unprotect(identity, kind, protected);
    try {
      if (bytes.isEmpty ||
          bytes.length > (kind == SyncLocalSecretKind.statusProof ? 512 : 43) ||
          bytes.any((byte) => byte < 0x21 || byte > 0x7e))
        throw const OperationFailure(FailureCode.protectionUnavailable);
      return _text(ascii.decode(bytes), kind);
    } catch (_) {
      throw const OperationFailure(FailureCode.protectionUnavailable);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<Uint8List> protectVaultKey(
    SyncIdentity identity,
    Uint8List key,
  ) async {
    if (key.length != 32) throw syncInvalidWire;
    final owned = Uint8List.fromList(key);
    try {
      return await _protect(identity, SyncLocalSecretKind.vaultKey, owned);
    } finally {
      owned.fillRange(0, owned.length, 0);
    }
  }

  Future<Uint8List> unprotectVaultKey(
    SyncIdentity identity,
    List<int> protected,
  ) async {
    final bytes = await _unprotect(
      identity,
      SyncLocalSecretKind.vaultKey,
      protected,
    );
    if (bytes.length != 32) {
      bytes.fillRange(0, bytes.length, 0);
      throw const OperationFailure(FailureCode.protectionUnavailable);
    }
    return bytes;
  }

  Future<Uint8List> _protect(
    SyncIdentity identity,
    SyncLocalSecretKind kind,
    Uint8List bytes,
  ) async {
    Uint8List? result;
    try {
      result = await port.protect(bytes, purpose(identity, kind));
      if (result.isEmpty || result.length > syncMaxRootBytes)
        throw syncInvalidWire;
      return result;
    } catch (_) {
      result?.fillRange(0, result.length, 0);
      throw const OperationFailure(FailureCode.protectionUnavailable);
    }
  }

  Future<Uint8List> _unprotect(
    SyncIdentity identity,
    SyncLocalSecretKind kind,
    List<int> protected,
  ) async {
    if (protected.isEmpty || protected.length > syncMaxRootBytes)
      throw const OperationFailure(FailureCode.protectionUnavailable);
    final input = Uint8List.fromList(protected);
    try {
      return await port.unprotect(input, purpose(identity, kind));
    } catch (_) {
      throw const OperationFailure(FailureCode.protectionUnavailable);
    } finally {
      input.fillRange(0, input.length, 0);
    }
  }
}
