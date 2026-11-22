import 'dart:convert';
import 'dart:typed_data';

import '../domain/models.dart';
import 'sync_models.dart';

const _invalid = OperationFailure(FailureCode.invalidArgument);

abstract final class SyncRecoveryCodec {
  static String encode(Uint8List key) {
    if (key.length != 32) throw _invalid;
    return 'SD1-${base64Url.encode(key).replaceAll('=', '')}-${syncSha256(key).substring(0, 8)}';
  }

  static Uint8List decode(String code) {
    final match = RegExp(r'^SD1-([A-Za-z0-9_-]{43})-([0-9a-f]{8})$')
        .firstMatch(code.trim());
    if (match == null) throw _invalid;
    Uint8List? key;
    try {
      key = base64Url.decode('${match[1]}=');
      if (key.length != 32 || encode(key) != match[0]) throw _invalid;
      return key;
    } catch (_) {
      key?.fillRange(0, key.length, 0);
      throw _invalid;
    }
  }
}
