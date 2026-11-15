import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_crypto.dart';
import 'package:serverdeck/sync/sync_http.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/sync/sync_recovery.dart';
import 'package:serverdeck/sync/sync_wire.dart';

import 'device_auth_test.dart' as auth;
import 'transport_test.dart' as wire;

Uint8List recoveryKey([int offset = 0]) =>
    Uint8List.fromList(List.generate(32, (i) => (i + offset) % 256));
SyncEncryptedRoot encryptedRoot(SyncIdentity identity, {int offset = 0}) {
  final crypto = SyncCrypto(identity: identity, rootKey: recoveryKey(offset));
  try {
    return crypto.encryptRoot(snapshotId: wire.id(4), revision: 1, entries: []);
  } finally {
    crypto.dispose();
  }
}

SyncManifest publicManifest(SyncEncryptedRoot root) => SyncManifest.parse({
  'version': 1,
  'content_version': 1,
  'vault_id': wire.id(3),
  'snapshot_id': wire.id(4),
  'revision': 1,
  'objects': <Object?>[],
  'root': {'sha256': root.ref.sha256, 'bytes': root.ref.bytes},
});
void serveRoot(auth.Harness h, SyncEncryptedRoot root, {bool corrupt = false}) {
  final manifest = publicManifest(root);
  h.handler = (request) async {
    if (request.uri.path == '/v1/vault/head')
      return wire.jsonResponse({
        'vault_id': wire.id(3),
        'revision': 1,
        'manifest': manifest.toJson(),
      });
    if (request.uri.path.startsWith('/v1/vault/blobs/'))
      return SyncHttpResponse(
        200,
        {
          'content-type': ['application/octet-stream'],
        },
        Stream.value(corrupt ? Uint8List(root.envelope.length) : root.envelope),
      );
    return null;
  };
}

void complete(FakeAsync clock, Future<void> future) {
  var done = false;
  future.then<void>((_) {
    done = true;
  });
  clock.flushMicrotasks();
  expect(done, isTrue);
}

Object fails(FakeAsync clock, Future<void> future) {
  Object? error;
  future.then<void>(
    (_) => fail('expected failure'),
    onError: (Object e) {
      error = e;
    },
  );
  clock.flushMicrotasks();
  expect(error, isNotNull);
  return error!;
}

void main() {
  test('vault reset clears protected and in-memory key; old code cannot initialize new state', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      serveRoot(h, encryptedRoot(h.repository.capture().identity));
      complete(
        clock,
        h.owner.vault.unlock(SyncRecoveryCodec.encode(recoveryKey())),
      );
      final crypto = h.owner.vault.withCrypto((value) => value);
      h.handler = (request) async {
        if (request.uri.path == '/v1/vault/head')
          return auth.remote('device_revoked', status: 403);
        if (request.uri.path == '/v1/device-status')
          return wire.jsonResponse({'status': 'vault_reset'});
        return null;
      };
      fails(clock, h.owner.vault.inspect());
      expect(h.owner.view.phase, SyncAuthPhase.vaultReset);
      expect(h.owner.vault.view.phase, SyncVaultPhase.unavailable);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      expect(
        () => crypto.deriveRootKey(wire.id(4)),
        throwsA(isA<OperationFailure>()),
      );
      final heads = h.count('/v1/vault/head');
      fails(
        clock,
        h.owner.vault.unlock(SyncRecoveryCodec.encode(recoveryKey())),
      );
      expect(h.count('/v1/vault/head'), heads);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      h.close();
    });
  });

  test(
    'key slot CAS does not replace a value changed during local protection',
    () {
      fakeAsync((clock) {
        final h = auth.Harness(clock);
        h.login();
        serveRoot(h, encryptedRoot(h.repository.capture().identity));
        final gate = Completer<void>();
        h.secrets.protecting = gate;
        Object? error;
        h.owner.vault
            .unlock(SyncRecoveryCodec.encode(recoveryKey()))
            .then<void>(
              (_) => fail('unexpected'),
              onError: (Object e) {
                error = e;
              },
            );
        clock.flushMicrotasks();
        h.domain.state.syncSecrets.protectedVaultRootKey = [99];
        gate.complete();
        clock.flushMicrotasks();
        expect(
          error,
          isA<OperationFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.conflict,
          ),
        );
        expect(h.domain.state.syncSecrets.protectedVaultRootKey, [99]);
        h.close();
      });
    },
  );

  test('locking during root body download cancels read before native key protection', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      final root = encryptedRoot(h.repository.capture().identity),
          manifest = publicManifest(root);
      var cancelled = false, failed = false;
      final stream = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      h.handler = (request) async {
        if (request.uri.path == '/v1/vault/head')
          return wire.jsonResponse({
            'vault_id': wire.id(3),
            'revision': 1,
            'manifest': manifest.toJson(),
          });
        if (request.uri.path.startsWith('/v1/vault/blobs/'))
          return SyncHttpResponse(200, {
            'content-type': ['application/octet-stream'],
          }, stream.stream);
        return null;
      };
      h.owner.vault
          .unlock(SyncRecoveryCodec.encode(recoveryKey()))
          .then<void>(
            (_) => fail('unexpected'),
            onError: (Object _) {
              failed = true;
            },
          );
      clock.flushMicrotasks();
      h.owner.vault.lock();
      clock.flushMicrotasks();
      expect(failed, isTrue);
      expect(cancelled, isTrue);
      expect(h.secrets.next, 4);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      stream.close();
      clock.flushMicrotasks();
      h.close();
    });
  });

  test(
    'invalid RNG output is wiped and cannot persist an initialization key',
    () {
      fakeAsync((clock) {
        final h = auth.Harness(clock);
        h.login();
        final raw = Uint8List(31)..fillRange(0, 31, 7);
        final vault = SyncVaultOwner(
          repository: h.repository,
          box: h.owner.box,
          access: h.owner,
          randomBytes: (_) => raw,
        );
        Object? error;
        vault.beginInitialization().then<void>(
          (_) => fail('unexpected'),
          onError: (Object e) {
            error = e;
          },
        );
        clock.flushMicrotasks();
        expect(
          error,
          isA<OperationFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.protectionUnavailable,
          ),
        );
        expect(raw.every((byte) => byte == 0), isTrue);
        expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
        vault.dispose();
        h.close();
      });
    },
  );
  test('local roots must authenticate with recovered key before any slot replacement', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      final identity = h.repository.capture().identity;
      final local = encryptedRoot(identity, offset: 1);
      serveRoot(h, encryptedRoot(identity));
      complete(
        clock,
        h.repository.stageRoot(
          h.repository.capture(),
          rootId: wire.id(30),
          snapshotId: wire.id(4),
          revision: 1,
          sourceGeneration: 0,
          rootCiphertext: local.envelope,
          objects: [],
          pending: true,
          commitId: wire.id(31),
        ),
      );
      h.domain.state.syncSecrets.protectedVaultRootKey = [99];
      expect(
        fails(
          clock,
          h.owner.vault.unlock(SyncRecoveryCodec.encode(recoveryKey())),
        ),
        isA<OperationFailure>().having(
          (e) => e.code,
          'code',
          FailureCode.cleanupRequired,
        ),
      );
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, [99]);
      expect(h.domain.state.syncState.pendingRootId, wire.id(30));
      h.close();
    });
  });

  test('root changes during protection reject stale key proof; retry validates new roots', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      final root = encryptedRoot(h.repository.capture().identity);
      serveRoot(h, root);
      final gate = Completer<void>();
      h.secrets.protecting = gate;
      Object? error;
      h.owner.vault
          .unlock(SyncRecoveryCodec.encode(recoveryKey()))
          .then<void>(
            (_) => fail('unexpected'),
            onError: (Object e) {
              error = e;
            },
          );
      clock.flushMicrotasks();
      complete(
        clock,
        h.repository.stageRoot(
          h.repository.capture(),
          rootId: wire.id(30),
          snapshotId: wire.id(4),
          revision: 1,
          sourceGeneration: 0,
          rootCiphertext: root.envelope,
          objects: [],
          pending: true,
          commitId: wire.id(31),
        ),
      );
      gate.complete();
      clock.flushMicrotasks();
      expect(
        error,
        isA<OperationFailure>().having(
          (e) => e.code,
          'code',
          FailureCode.conflict,
        ),
      );
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      complete(
        clock,
        h.owner.vault.unlock(SyncRecoveryCodec.encode(recoveryKey())),
      );
      expect(h.owner.vault.view.phase, SyncVaultPhase.ready);
      expect(h.domain.state.syncState.pendingRootId, wire.id(30));
      h.close();
    });
  });

  test(
    'concurrent refresh and key protection preserve both latest secret slots',
    () {
      fakeAsync((clock) {
        final h = auth.Harness(clock);
        h.login();
        serveRoot(h, encryptedRoot(h.repository.capture().identity));
        final gate = Completer<void>();
        h.secrets.protecting = gate;
        var unlocked = false, refreshed = false;
        h.owner.vault
            .unlock(SyncRecoveryCodec.encode(recoveryKey()))
            .then<void>((_) {
              unlocked = true;
            });
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 900));
        h.owner.accessToken().then<void>((_) {
          refreshed = true;
        });
        clock.flushMicrotasks();
        gate.complete();
        clock.flushMicrotasks();
        expect(unlocked, isTrue);
        expect(refreshed, isTrue);
        final saved = h.domain.state.syncSecrets;
        expect(
          ascii.decode(h.secrets.entries[saved.protectedRefresh!.single]!.$2),
          wire.token(6),
        );
        expect(
          h.secrets.entries[saved.protectedVaultRootKey!.single]!.$2,
          recoveryKey(),
        );
        expect(saved.protectedStatusProof, [3]);
        h.close();
      });
    },
  );
  test('recovery exact synthetic encoding, canonical base64url/checksum and trim only', () {
    final key = recoveryKey();
    const code = 'SD1-AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8-630dcd29';
    expect(SyncRecoveryCodec.encode(key), code);
    expect(code.length, 56);
    final decoded = SyncRecoveryCodec.decode(' \n$code\t');
    expect(decoded, key);
    decoded.fillRange(0, 32, 0);
    for (final value in [
      code.toLowerCase(),
      code.replaceFirst('630dcd29', '630DCD29'),
      '$code=',
      code.replaceFirst('SD1-', 'SD2-'),
      code.replaceFirst('DA0', 'D A0'),
      code.replaceFirst('Hh8', 'Hh9'),
      code.replaceFirst('630dcd29', '00000000'),
      'x$code',
      code.substring(1),
    ]) {
      expect(
        () => SyncRecoveryCodec.decode(value),
        throwsA(isA<OperationFailure>()),
        reason: value,
      );
    }
    expect(
      () => SyncRecoveryCodec.encode(Uint8List(31)),
      throwsA(isA<OperationFailure>()),
    );
  });

  test('empty vault initialization requires saved acknowledgment and checksum before protection', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      complete(clock, h.owner.vault.inspect());
      expect(h.owner.vault.view.phase, SyncVaultPhase.needsInitialization);
      SyncRecoveryChallenge? challenge;
      h.owner.vault.beginInitialization().then<void>((value) {
        challenge = value;
      });
      clock.flushMicrotasks();
      final draft = challenge!, code = draft.code;
      expect(h.owner.vault.view.phase, SyncVaultPhase.awaitingConfirmation);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      fails(
        clock,
        h.owner.vault.confirmInitialization(
          draft,
          saved: false,
          checksum: draft.checksum,
        ),
      );
      fails(
        clock,
        h.owner.vault.confirmInitialization(
          draft,
          saved: true,
          checksum: '00000000',
        ),
      );
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      complete(
        clock,
        h.owner.vault.confirmInitialization(
          draft,
          saved: true,
          checksum: ' ${draft.checksum} ',
        ),
      );
      expect(h.owner.vault.view.phase, SyncVaultPhase.ready);
      expect(draft.disposed, isTrue);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, [4]);
      final encoded = SyncRecoveryCodec.decode(code);
      expect(h.secrets.entries[4]!.$2, encoded);
      encoded.fillRange(0, 32, 0);
      expect(h.count('/v1/vault/uploads'), 0);
      expect(
        h.secrets.inputs.every((bytes) => bytes.every((b) => b == 0)),
        isTrue,
      );
      expect(
        h.secrets.outputs.every((bytes) => bytes.every((b) => b == 0)),
        isTrue,
      );
      h.close();
    });
  });

  test(
    'cancel disposes draft; later initialization uses independent random key',
    () {
      fakeAsync((clock) {
        final h = auth.Harness(clock);
        h.login();
        SyncRecoveryChallenge? draft;
        h.owner.vault.beginInitialization().then<void>((value) {
          draft = value;
        });
        clock.flushMicrotasks();
        final first = draft!, code = first.code;
        h.owner.vault.cancelInitialization(first);
        expect(first.disposed, isTrue);
        expect(() => first.code, throwsA(isA<OperationFailure>()));
        expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
        h.owner.vault.beginInitialization().then<void>((value) {
          draft = value;
        });
        clock.flushMicrotasks();
        expect(draft!.code, isNot(code));
        h.owner.vault.cancelInitialization(draft!);
        h.close();
      });
    },
  );

  test('existing vault code authenticates root before storing a platform wrapped key', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      final root = encryptedRoot(h.repository.capture().identity);
      serveRoot(h, root);
      complete(clock, h.owner.vault.inspect());
      expect(h.owner.vault.view.phase, SyncVaultPhase.locked);
      complete(
        clock,
        h.owner.vault.unlock(SyncRecoveryCodec.encode(recoveryKey())),
      );
      expect(h.owner.vault.view.phase, SyncVaultPhase.ready);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, [4]);
      h.owner.vault.withCrypto(
        (crypto) => expect(
          crypto
              .decryptRoot(
                envelope: root.envelope,
                root: root.ref,
                objects: [],
                snapshotId: wire.id(4),
                revision: 1,
              )
              .revision,
          1,
        ),
      );
      expect(h.domain.state.syncState.baseRevision, 0);
      expect(h.domain.state.profiles, isEmpty);
      h.close();
    });
  });

  test('wrong but checksummed key, malformed code and corrupt root preserve saved state', () {
    for (final corrupt in [false, true])
      fakeAsync((clock) {
        final h = auth.Harness(clock);
        h.login();
        final root = encryptedRoot(h.repository.capture().identity);
        serveRoot(h, root, corrupt: corrupt);
        h.domain.state.syncSecrets.protectedVaultRootKey = [99];
        final before = h.domain.committedWrites;
        final error = fails(
          clock,
          h.owner.vault.unlock(
            SyncRecoveryCodec.encode(recoveryKey(corrupt ? 0 : 1)),
          ),
        );
        expect(error, isA<OperationFailure>());
        expect(h.domain.state.syncSecrets.protectedVaultRootKey, [99]);
        expect(h.domain.committedWrites, before);
        expect(h.owner.vault.view.phase, SyncVaultPhase.error);
        fails(clock, h.owner.vault.unlock('synthetic invalid secret sentinel'));
        expect(h.owner.vault.view.errorCode, isNot(contains('sentinel')));
        h.close();
      });
  });

  test('empty vault cannot authenticate supplied code; nonempty vault cannot initialize', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      fails(
        clock,
        h.owner.vault.unlock(SyncRecoveryCodec.encode(recoveryKey())),
      );
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      final root = encryptedRoot(h.repository.capture().identity);
      serveRoot(h, root);
      Object? error;
      h.owner.vault.beginInitialization().then<void>(
        (_) => fail('unexpected'),
        onError: (Object e) {
          error = e;
        },
      );
      clock.flushMicrotasks();
      expect(error, isA<OperationFailure>());
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      h.close();
    });
  });

  test('remote changed after code display prevents initialization instead of overwriting', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      SyncRecoveryChallenge? challenge;
      h.owner.vault.beginInitialization().then<void>((value) {
        challenge = value;
      });
      clock.flushMicrotasks();
      serveRoot(h, encryptedRoot(h.repository.capture().identity));
      fails(
        clock,
        h.owner.vault.confirmInitialization(
          challenge!,
          saved: true,
          checksum: challenge!.checksum,
        ),
      );
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      expect(h.count('/v1/vault/uploads'), 0);
      h.owner.vault.cancelInitialization(challenge!);
      h.close();
    });
  });

  test(
    'pause while protection or disk check is pending cannot persist a late key',
    () {
      for (final protecting in [false, true])
        fakeAsync((clock) {
          final h = auth.Harness(clock);
          h.login();
          SyncRecoveryChallenge? challenge;
          h.owner.vault.beginInitialization().then<void>((value) {
            challenge = value;
          });
          clock.flushMicrotasks();
          final gate = Completer<void>();
          if (protecting)
            h.secrets.protecting = gate;
          else
            h.domain.beforeWrite = () => gate.future;
          var failed = false;
          h.owner.vault
              .confirmInitialization(
                challenge!,
                saved: true,
                checksum: challenge!.checksum,
              )
              .then<void>(
                (_) => fail('unexpected'),
                onError: (Object _) {
                  failed = true;
                },
              );
          clock.flushMicrotasks();
          h.owner.pause();
          gate.complete();
          clock.flushMicrotasks();
          expect(failed, isTrue);
          expect(challenge!.disposed, isTrue);
          expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
          expect(h.owner.vault.view.phase, SyncVaultPhase.unavailable);
          h.close();
        });
    },
  );

  test(
    'failed key protection or commit leaves previous saved key/auth untouched',
    () {
      for (final protect in [false, true])
        fakeAsync((clock) {
          final h = auth.Harness(clock);
          h.login();
          serveRoot(h, encryptedRoot(h.repository.capture().identity));
          h.domain.state.syncSecrets.protectedVaultRootKey = [99];
          if (protect)
            h.secrets.failProtect = true;
          else
            h.domain.failCommit = true;
          fails(
            clock,
            h.owner.vault.unlock(SyncRecoveryCodec.encode(recoveryKey())),
          );
          expect(h.domain.state.syncSecrets.protectedVaultRootKey, [99]);
          expect(h.domain.state.syncSecrets.protectedRefresh, [2]);
          expect(h.domain.state.syncState.baseRevision, 0);
          h.close();
        });
    },
  );

  test('protected key restores only with matching root and pause disposes captured crypto', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      final root = encryptedRoot(h.repository.capture().identity);
      serveRoot(h, root);
      complete(
        clock,
        h.owner.vault.unlock(SyncRecoveryCodec.encode(recoveryKey())),
      );
      final crypto = h.owner.vault.withCrypto((value) => value);
      h.owner.vault.lock();
      expect(
        () => crypto.deriveRootKey(wire.id(4)),
        throwsA(isA<OperationFailure>()),
      );
      complete(clock, h.owner.vault.inspect());
      expect(h.owner.vault.view.phase, SyncVaultPhase.ready);
      final again = h.owner.vault.withCrypto((value) => value);
      h.owner.pause();
      expect(
        () => again.deriveRootKey(wire.id(4)),
        throwsA(isA<OperationFailure>()),
      );
      h.close();
    });
  });

  test('key is never sent to transport; rollback anchor prevents key acceptance', () {
    fakeAsync((clock) {
      final h = auth.Harness(clock);
      h.login();
      final root = encryptedRoot(h.repository.capture().identity),
          manifest = publicManifest(root);
      final requests = <String>[];
      h.handler = (request) async {
        requests.add(
          '${request.uri} ${request.body == null ? '' : utf8.decode(request.body!)}',
        );
        if (request.uri.path == '/v1/vault/head')
          return wire.jsonResponse({
            'vault_id': wire.id(3),
            'revision': 1,
            'manifest': manifest.toJson(),
          });
        if (request.uri.path.startsWith('/v1/vault/blobs/'))
          return SyncHttpResponse(200, {
            'content-type': ['application/octet-stream'],
          }, Stream.value(root.envelope));
        return null;
      };
      final code = SyncRecoveryCodec.encode(recoveryKey());
      complete(clock, h.owner.vault.unlock(code));
      expect(
        requests.any(
          (value) =>
              value.contains(code) ||
              value.contains(
                base64Url.encode(recoveryKey()).replaceAll('=', ''),
              ),
        ),
        isFalse,
      );
      h.owner.vault.lock();
      h.domain.state.syncState.baseRevision = 2;
      fails(clock, h.owner.vault.inspect());
      expect(h.owner.vault.view.errorCode, 'CONFLICT');
      h.close();
    });
  });
}
