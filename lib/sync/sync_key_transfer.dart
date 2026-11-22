import 'dart:convert';
import 'dart:typed_data';

import '../domain/models.dart';
import 'sync_json.dart';
import 'sync_models.dart';
import 'sync_recovery_code.dart';

const _invalid = OperationFailure(FailureCode.invalidArgument);

/// Ephemeral secret, never a normal view, wire record or domain projection.
final class SyncKeyTransfer {
  SyncKeyTransfer.fromKey(this.identity, Uint8List key)
    : _key = Uint8List.fromList(key) {
    if (_key.length != 32) {
      dispose();
      throw _invalid;
    }
  }
  final SyncIdentity identity;
  final Uint8List _key;
  bool _disposed = false;
  bool get disposed => _disposed;
  String get recoveryCode {
    if (_disposed) throw _invalid;
    return SyncRecoveryCodec.encode(_key);
  }

  String get payload {
    final bytes = canonicalSyncJson({
      'origin': identity.serviceOrigin,
      'accountId': identity.accountId,
      'vaultId': identity.vaultId,
      'recoveryCode': recoveryCode,
    });
    try {
      final value = 'SDQR1:${base64Url.encode(bytes).replaceAll('=', '')}';
      if (bytes.length > 1536 || value.length > 2048) throw _invalid;
      return value;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static SyncKeyTransfer parse(String input, SyncIdentity expected) {
    Uint8List? bytes, key;
    try {
      if (input.length > 2048 || !input.startsWith('SDQR1:')) throw _invalid;
      final encoded = input.substring(6);
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) throw _invalid;
      bytes = base64Url.decode(base64Url.normalize(encoded));
      if (base64Url.encode(bytes).replaceAll('=', '') != encoded)
        throw _invalid;
      final value = strictSyncJson(bytes, maxBytes: 1536, canonical: true);
      if (value is! Map<String, Object?> ||
          value.length != 4 ||
          value['origin'] != expected.serviceOrigin ||
          value['accountId'] != expected.accountId ||
          value['vaultId'] != expected.vaultId ||
          value['recoveryCode'] is! String)
        throw _invalid;
      key = SyncRecoveryCodec.decode(value['recoveryCode']! as String);
      if (SyncRecoveryCodec.encode(key) != value['recoveryCode'])
        throw _invalid;
      return SyncKeyTransfer.fromKey(expected, key);
    } catch (_) {
      throw _invalid;
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      key?.fillRange(0, key.length, 0);
    }
  }

  void dispose() {
    _key.fillRange(0, _key.length, 0);
    _disposed = true;
  }

  @override
  String toString() => 'SyncKeyTransfer(secret)';
}
