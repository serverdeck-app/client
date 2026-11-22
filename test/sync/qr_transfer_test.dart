import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_json.dart';
import 'package:serverdeck/sync/sync_key_transfer.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_recovery.dart';

import 'device_auth_test.dart' as auth;
import 'recovery_test.dart' as recovery;
import 'transport_test.dart' as wire;

SyncIdentity identity({
  String? origin,
  String? account,
  String? vault,
  int device = 2,
}) => SyncIdentity(
  serviceOrigin: origin ?? wire.origin.value,
  accountId: account ?? wire.id(1),
  deviceId: wire.id(device),
  vaultId: vault ?? wire.id(3),
);
String raw(Map<String, Object?> value) =>
    'SDQR1:${base64Url.encode(canonicalSyncJson(value)).replaceAll('=', '')}';
void main() {
  test(
    'optical round trip binds vault but permits a different receiving device',
    () {
      final source = SyncKeyTransfer.fromKey(
        identity(),
        recovery.recoveryKey(),
      );
      final target = SyncKeyTransfer.parse(source.payload, identity(device: 8));
      expect(target.recoveryCode, source.recoveryCode);
      expect(source.toString(), isNot(contains('SD1-')));
      source.dispose();
      target.dispose();
      expect(() => source.payload, throwsA(isA<OperationFailure>()));
    },
  );
  test(
    'different origin/account/vault rejected without any guessed identity',
    () {
      final source = SyncKeyTransfer.fromKey(
        identity(),
        recovery.recoveryKey(),
      );
      for (final other in [
        identity(origin: 'https://other.example'),
        identity(account: wire.id(9)),
        identity(vault: wire.id(9)),
      ]) {
        expect(
          () => SyncKeyTransfer.parse(source.payload, other),
          throwsA(isA<OperationFailure>()),
        );
      }
      source.dispose();
    },
  );
  test(
    'reject unknown versions, padding, malformed or unbounded optical input',
    () {
      final transfer = SyncKeyTransfer.fromKey(
        identity(),
        recovery.recoveryKey(),
      );
      for (final bad in [
        'SDQR2:${transfer.payload.substring(6)}',
        transfer.recoveryCode,
        '${transfer.payload}=',
        ' ${transfer.payload}',
        'SDQR1:!',
        'SDQR1:${'a' * 2048}',
      ]) {
        expect(
          () => SyncKeyTransfer.parse(bad, identity()),
          throwsA(isA<OperationFailure>()),
        );
      }
      final fields = <String, Object?>{
        'origin': wire.origin.value,
        'accountId': wire.id(1),
        'vaultId': wire.id(3),
        'recoveryCode': transfer.recoveryCode,
      };
      for (final value in [
        {...fields, 'extra': 'x'},
        {...fields, 'recoveryCode': 'bad'},
        {...fields}..remove('vaultId'),
      ]) {
        expect(
          () => SyncKeyTransfer.parse(raw(value), identity()),
          throwsA(isA<OperationFailure>()),
        );
      }
      final duplicate = utf8.encode('{"origin":"x","origin":"y"}');
      expect(
        () => SyncKeyTransfer.parse(
          'SDQR1:${base64Url.encode(duplicate).replaceAll('=', '')}',
          identity(),
        ),
        throwsA(isA<OperationFailure>()),
      );
      transfer.dispose();
    },
  );
  test('captured import uses root authentication and protected key persistence only', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      recovery.serveRoot(
        h,
        recovery.encryptedRoot(h.repository.capture().identity),
      );
      recovery.complete(clock, h.owner.vault.inspect());
      final capture = h.owner.vault.captureQrImport();
      final transfer = SyncKeyTransfer.fromKey(
        capture.identity,
        recovery.recoveryKey(),
      );
      recovery.complete(clock, h.owner.vault.unlockQr(transfer, capture));
      expect(h.owner.vault.view.phase, SyncVaultPhase.ready);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNotNull);
      expect(h.count('/v1/vault/uploads'), 0);
      transfer.dispose();
      h.close();
    });
  });
  test('wrong key and changed binding never replace protected key', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      recovery.serveRoot(
        h,
        recovery.encryptedRoot(h.repository.capture().identity),
      );
      recovery.complete(clock, h.owner.vault.inspect());
      final capture = h.owner.vault.captureQrImport();
      final wrong = SyncKeyTransfer.fromKey(
        capture.identity,
        recovery.recoveryKey(1),
      );
      recovery.fails(clock, h.owner.vault.unlockQr(wrong, capture));
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      final current = h.owner.vault.captureQrImport();
      final foreign = SyncKeyTransfer.fromKey(
        identity(account: wire.id(9)),
        recovery.recoveryKey(),
      );
      final heads = h.count('/v1/vault/head');
      recovery.fails(clock, h.owner.vault.unlockQr(foreign, current));
      expect(h.count('/v1/vault/head'), heads);
      wrong.dispose();
      foreign.dispose();
      h.close();
    });
  });
  test(
    'stale capture cannot unlock after pause or another owner operation',
    () {
      fakeAsync((clock) {
        final h = auth.Harness(clock);
        h.login();
        recovery.serveRoot(
          h,
          recovery.encryptedRoot(h.repository.capture().identity),
        );
        recovery.complete(clock, h.owner.vault.inspect());
        final capture = h.owner.vault.captureQrImport();
        final transfer = SyncKeyTransfer.fromKey(
          capture.identity,
          recovery.recoveryKey(),
        );
        h.owner.pause();
        recovery.fails(clock, h.owner.vault.unlockQr(transfer, capture));
        expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
        transfer.dispose();
        h.close();
      });
    },
  );
  test(
    'export proves current remote key and returns a disposable optical secret',
    () {
      fakeAsync((clock) {
        final h = auth.Harness(clock);
        h.login();
        recovery.serveRoot(
          h,
          recovery.encryptedRoot(h.repository.capture().identity),
        );
        recovery.complete(
          clock,
          h.owner.vault.unlock(
            SyncRecoveryCodec.encode(recovery.recoveryKey()),
          ),
        );
        SyncKeyTransfer? transfer;
        recovery.complete(
          clock,
          h.owner.vault.exportQr().then<void>((value) => transfer = value),
        );
        expect(
          transfer!.recoveryCode,
          SyncRecoveryCodec.encode(recovery.recoveryKey()),
        );
        transfer!.dispose();
        recovery.serveRoot(
          h,
          recovery.encryptedRoot(h.repository.capture().identity, offset: 1),
        );
        recovery.fails(
          clock,
          h.owner.vault.exportQr().then<void>((value) {
            value.dispose();
          }),
        );
        expect(h.owner.vault.view.phase, SyncVaultPhase.ready);
        h.close();
      });
    },
  );
  test('late export response is rejected after locking', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      recovery.serveRoot(
        h,
        recovery.encryptedRoot(h.repository.capture().identity),
      );
      recovery.complete(
        clock,
        h.owner.vault.unlock(SyncRecoveryCodec.encode(recovery.recoveryKey())),
      );
      final gate = Completer<void>();
      final original = h.handler!;
      h.handler = (request) async {
        await gate.future;
        return original(request);
      };
      Object? error;
      h.owner.vault.exportQr().then<void>(
        (value) {
          value.dispose();
          fail('late export');
        },
        onError: (Object e) {
          error = e;
        },
      );
      clock.flushMicrotasks();
      h.owner.vault.lock();
      gate.complete();
      clock.flushMicrotasks();
      expect(error, isNotNull);
      h.close();
    });
  });
}
