import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/sync/sync_wire.dart';

import 'transport_test.dart' as wire;

void main() {
  test('VK account accepts null email without changing native identity', () {
    final input = wire.session()..['email'] = null;
    final parsed = SyncNativeSession.parse(input, wire.origin);
    expect(parsed.email, isNull);
    expect(parsed.accountId, input['account_id']);
    expect(parsed.deviceId, input['device_id']);
    expect(parsed.vaultId, input['vault_id']);
  });

  test('legacy email and strict native contract remain validated', () {
    final input = wire.session();
    expect(SyncNativeSession.parse(input, wire.origin).email, input['email']);
    for (final value in [123, true, <String>[], '', 'not-an-email', 'a\nb@c']) {
      expect(
        () => SyncNativeSession.parse({...input, 'email': value}, wire.origin),
        wire.invalid,
      );
    }
    expect(
      () => SyncNativeSession.parse({...input}..remove('email'), wire.origin),
      wire.invalid,
    );
  });
}
