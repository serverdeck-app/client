import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/runtime/platform_ports.dart';
import 'package:serverdeck/storage/records.dart';
import 'package:serverdeck/sync/sync_http.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/sync/sync_repository.dart';
import 'package:serverdeck/sync/sync_secret_box.dart';
import 'package:serverdeck/sync/sync_transport.dart';
import 'package:serverdeck/sync/sync_wire.dart';

import '../fixtures/domain_repository.dart';
import 'transport_test.dart' as wire;

final class SecretPort implements PlatformSecretPort {
  final entries = <int, (String, Uint8List)>{};
  final inputs = <Uint8List>[], outputs = <Uint8List>[];
  Completer<void>? protecting;
  bool failProtect = false, failUnprotect = false;
  int next = 1;
  @override
  Future<Uint8List> protect(Uint8List bytes, String purpose) async {
    inputs.add(bytes);
    final copy = Uint8List.fromList(bytes);
    if (protecting != null) await protecting!.future;
    if (failProtect) throw StateError('synthetic secret sentinel');
    final id = next++;
    entries[id] = (purpose, copy);
    final result = Uint8List.fromList([id]);
    outputs.add(result);
    return result;
  }

  @override
  Future<Uint8List> unprotect(Uint8List bytes, String purpose) async {
    inputs.add(bytes);
    if (failUnprotect ||
        bytes.length != 1 ||
        entries[bytes.single]?.$1 != purpose)
      throw StateError('synthetic secret sentinel');
    final result = Uint8List.fromList(entries[bytes.single]!.$2);
    outputs.add(result);
    return result;
  }
}

final class Browser implements PlatformBrowserPort {
  final pages = <Uri>[];
  bool fail = false;
  @override
  Future<void> openServicePage({
    required Uri serviceOrigin,
    required Uri page,
  }) async {
    expectSync(serviceOrigin.toString(), wire.origin.value);
    pages.add(page);
    if (fail) throw StateError('synthetic secret sentinel');
  }
}

final class Harness {
  Harness(this.clock) {
    repository = SyncRepository(
      domain,
      availableStorageBytes: () async => 100 * 1024 * 1024 * 1024,
    );
    http = wire.FakeHttp((request, _) async {
      final custom = handler;
      if (custom != null) {
        final response = await custom(request);
        if (response != null) return response;
      }
      return switch (request.uri.path) {
        '/v1/device-authorizations' => wire.jsonResponse(
          wire.authorization(),
          status: 201,
        ),
        '/v1/device-token' => wire.jsonResponse(wire.session()),
        '/v1/token/refresh' => refreshResponse(),
        '/v1/device-status' => wire.jsonResponse({'status': 'active'}),
        '/v1/vault/head' => wire.jsonResponse({
          'vault_id': wire.id(3),
          'revision': 0,
          'manifest': null,
        }),
        _ => throw StateError('unexpected test URI'),
      };
    });
    owner = newOwner();
  }
  final FakeAsync clock;
  final domain = MemoryDomainRepository();
  final secrets = SecretPort();
  final browser = Browser();
  late final SyncRepository repository;
  late final wire.FakeHttp http;
  late SyncOwner owner;
  Future<SyncHttpResponse?> Function(SyncHttpRequest)? handler;
  SyncOwner newOwner() => SyncOwner(
    repository: repository,
    secrets: secrets,
    browser: browser,
    transport: (origin) => SyncTransport(origin: origin, http: http),
    monotonicMicros: () => clock.elapsed.inMicroseconds,
  );
  SyncHttpResponse refreshResponse() {
    expectSync(domain.state.syncState.errorCode, syncRefreshInFlight);
    return wire.jsonResponse({
      'access_token': wire.token(5),
      'refresh_token': wire.token(6),
      'expires_in': 900,
    });
  }

  int count(String path) =>
      http.requests.where((request) => request.uri.path == path).length;
  void begin() {
    owner
        .beginLogin(origin: wire.origin, platform: 'windows', name: 'Desktop')
        .then<void>(
          (_) {},
          onError: (Object error) => fail('unexpected ${error.runtimeType}'),
        );
    clock.flushMicrotasks();
    expect(owner.view.phase, SyncAuthPhase.awaitingApproval);
  }

  void login() {
    begin();
    clock.elapse(const Duration(seconds: 5));
    clock.flushMicrotasks();
    expect(owner.view.phase, SyncAuthPhase.signedIn);
  }

  void close() {
    owner.dispose();
    clock.flushMicrotasks();
    expect(clock.nonPeriodicTimerCount, 0);
  }
}

SyncHttpResponse remote(String code, {int status = 400}) => wire.jsonResponse({
  'error': code,
  'request_id': wire.id(9),
}, status: status);

void main() {
  test(
    'cancel or pause-resume before first login continuation creates no effects',
    () {
      for (final loaded in [false, true])
        for (final pause in [false, true])
          fakeAsync((clock) {
            final h = Harness(clock);
            if (loaded) h.login();
            final requests = h.http.requests.length,
                pages = h.browser.pages.length;
            var cancelled = false;
            h.owner
                .beginLogin(
                  origin: wire.origin,
                  platform: 'windows',
                  name: 'Desktop',
                )
                .then<void>(
                  (_) => fail('unexpected'),
                  onError: (Object e) {
                    expect(e, isA<SyncTransportCancelled>());
                    cancelled = true;
                  },
                );
            if (pause) {
              h.owner.pause();
              h.owner.resume();
            } else {
              h.owner.cancelLogin();
            }
            clock.flushMicrotasks();
            expect(cancelled, isTrue);
            expect(h.http.requests.length, requests);
            expect(h.browser.pages.length, pages);
            expect(clock.nonPeriodicTimerCount, 0);
            expect(h.domain.state.syncState.enabled, loaded);
            h.close();
          });
    },
  );

  test(
    'overlapping explicit login starts supersede once without a second flow',
    () {
      fakeAsync((clock) {
        final h = Harness(clock);
        var started = 0, cancelled = 0;
        for (var n = 0; n < 2; n++)
          h.owner
              .beginLogin(
                origin: wire.origin,
                platform: 'windows',
                name: 'Desktop',
              )
              .then<void>(
                (_) {
                  started++;
                },
                onError: (Object e) {
                  expect(e, isA<SyncTransportCancelled>());
                  cancelled++;
                },
              );
        clock.flushMicrotasks();
        expect(started, 1);
        expect(cancelled, 1);
        expect(h.count('/v1/device-authorizations'), 1);
        expect(h.browser.pages.length, 1);
        expect(clock.nonPeriodicTimerCount, 1);
        h.close();
      });
    },
  );

  test('access entry cancelled before restore continuation cannot refresh after resume', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.login();
      var cancelled = false;
      h.owner.accessToken().then<void>(
        (_) => fail('unexpected'),
        onError: (Object e) {
          expect(e, isA<SyncTransportCancelled>());
          cancelled = true;
        },
      );
      h.owner.pause();
      h.owner.resume();
      clock.flushMicrotasks();
      expect(cancelled, isTrue);
      expect(h.count('/v1/token/refresh'), 0);
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      h.close();
    });
  });
  test('caller arriving after refresh intent joins pending HTTP instead of AUTH_REQUIRED', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.login();
      final response = Completer<SyncHttpResponse>();
      h.handler = (request) async =>
          request.uri.path == '/v1/token/refresh' ? response.future : null;
      clock.elapse(const Duration(seconds: 900));
      var complete = 0, actions = 0;
      h.owner.accessToken().then<void>((token) {
        expect(token.value, wire.token(5));
        complete++;
      });
      clock.flushMicrotasks();
      expect(h.domain.state.syncState.errorCode, syncRefreshInFlight);
      h.owner.accessToken().then<void>((token) {
        expect(token.value, wire.token(5));
        complete++;
      });
      h.owner
          .withAccess((transport, access, cancel) async {
            actions++;
            return access.value;
          })
          .then<void>((value) {
            expect(value, wire.token(5));
            complete++;
          });
      clock.flushMicrotasks();
      expect(complete, 0);
      expect(actions, 0);
      expect(h.count('/v1/token/refresh'), 1);
      h.domain.state.syncSecrets.protectedVaultRootKey = [99];
      response.complete(h.refreshResponseForLateTest());
      clock.flushMicrotasks();
      expect(complete, 3);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, [99]);
      expect(actions, 1);
      expect(h.count('/v1/token/refresh'), 1);
      h.close();
    });
  });

  test('pause at refresh-complete notification prevents starting an awaiting data action', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.login();
      final subscription = h.owner.changes.listen((view) {
        if (view.phase == SyncAuthPhase.signedIn) h.owner.pause();
      });
      clock.elapse(const Duration(seconds: 900));
      var cancelled = false, actions = 0;
      h.owner
          .withAccess((transport, access, cancel) async {
            actions++;
            return 1;
          })
          .then<void>(
            (_) => fail('unexpected'),
            onError: (Object e) {
              expect(e, isA<SyncTransportCancelled>());
              cancelled = true;
            },
          );
      clock.flushMicrotasks();
      expect(cancelled, isTrue);
      expect(actions, 0);
      expect(h.owner.view.phase, SyncAuthPhase.paused);
      subscription.cancel();
      clock.flushMicrotasks();
      h.close();
    });
  });
  test('healthy process restart restores protected identity then refreshes before data', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.login();
      h.owner.dispose();
      h.owner = h.newOwner();
      h.owner.restoreSession();
      clock.flushMicrotasks();
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      expect(h.count('/v1/token/refresh'), 0);
      SyncHead? head;
      h.owner
          .withAccess(
            (transport, access, cancel) =>
                transport.head(access, vaultId: wire.id(3), cancel: cancel),
          )
          .then<void>((value) {
            head = value;
          });
      clock.flushMicrotasks();
      expect(head?.revision, 0);
      expect(h.count('/v1/token/refresh'), 1);
      expect(
        h.secrets.inputs.every((bytes) => bytes.every((byte) => byte == 0)),
        isTrue,
      );
      h.close();
    });
  });
  test('persistent storage failure after refresh intent still blocks in-memory admission', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.login();
      h.handler = (request) async {
        if (request.uri.path != '/v1/token/refresh') return null;
        h.domain.beforeWrite = () async {
          throw StateError('synthetic storage failure');
        };
        return h.refreshResponse();
      };
      clock.elapse(const Duration(seconds: 900));
      var failures = 0;
      h.owner.accessToken().then<void>(
        (_) => fail('unexpected'),
        onError: (Object _) {
          failures++;
        },
      );
      clock.flushMicrotasks();
      expect(failures, 1);
      expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
      expect(h.domain.state.syncState.errorCode, syncRefreshInFlight);
      h.owner.accessToken().then<void>(
        (_) => fail('unexpected'),
        onError: (Object _) {
          failures++;
        },
      );
      clock.flushMicrotasks();
      expect(failures, 2);
      expect(h.count('/v1/token/refresh'), 1);
      h.close();
    });
  });

  test('late refresh cannot persist into a newly bound account', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.login();
      final pending = Completer<SyncHttpResponse>();
      h.handler = (request) async =>
          request.uri.path == '/v1/token/refresh' ? pending.future : null;
      clock.elapse(const Duration(seconds: 900));
      h.owner.accessToken().then<void>(
        (_) => fail('unexpected'),
        onError: (Object e) {
          expect(e, isA<SyncTransportCancelled>());
        },
      );
      clock.flushMicrotasks();
      h.repository.detach(h.repository.capture());
      clock.flushMicrotasks();
      final generation = h.domain.state.syncState.identityGeneration;
      h.repository.bind(
        expectedGeneration: generation,
        identity: SyncIdentity(
          serviceOrigin: wire.origin.value,
          accountId: wire.id(81),
          deviceId: wire.id(82),
          vaultId: wire.id(83),
        ),
        secrets: SyncSecretRecord()
          ..protectedAccess = [81]
          ..protectedRefresh = [82]
          ..protectedStatusProof = [83],
      );
      clock.flushMicrotasks();
      pending.complete(h.refreshResponseForLateTest());
      clock.flushMicrotasks();
      expect(h.domain.state.syncState.accountId, wire.id(81));
      expect(h.domain.state.syncSecrets.protectedRefresh, [82]);
      h.close();
    });
  });
  test('late concurrent 401 after completed refresh reuses the rotated access token', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.login();
      final late = Completer<SyncHttpResponse>();
      var heads = 0, success = 0;
      h.handler = (request) async {
        if (request.uri.path != '/v1/vault/head') return null;
        heads++;
        if (heads == 1) return remote('token_expired', status: 401);
        if (heads == 2) return late.future;
        return null;
      };
      for (var n = 0; n < 2; n++)
        h.owner
            .withAccess(
              (transport, access, cancel) =>
                  transport.head(access, vaultId: wire.id(3), cancel: cancel),
            )
            .then<void>((_) {
              success++;
            });
      clock.flushMicrotasks();
      expect(success, 1);
      expect(h.count('/v1/token/refresh'), 1);
      late.complete(remote('token_expired', status: 401));
      clock.flushMicrotasks();
      expect(success, 2);
      expect(h.count('/v1/token/refresh'), 1);
      h.close();
    });
  });

  test(
    'refresh protection or commit failure cannot replay a consumed refresh',
    () {
      for (final protect in [false, true])
        fakeAsync((clock) {
          final h = Harness(clock);
          h.login();
          h.handler = (request) async {
            if (request.uri.path != '/v1/token/refresh') return null;
            if (protect)
              h.secrets.failProtect = true;
            else
              h.domain.failCommit = true;
            return h.refreshResponse();
          };
          clock.elapse(const Duration(seconds: 900));
          var failures = 0;
          h.owner.accessToken().then<void>(
            (_) => fail('unexpected'),
            onError: (Object _) {
              failures++;
            },
          );
          clock.flushMicrotasks();
          expect(failures, 1);
          expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
          h.owner.accessToken().then<void>(
            (_) => fail('unexpected'),
            onError: (Object _) {
              failures++;
            },
          );
          clock.flushMicrotasks();
          expect(failures, 2);
          expect(h.count('/v1/token/refresh'), 1);
          expect(h.domain.state.syncState.errorCode, syncLoginRequired);
          h.close();
        });
    },
  );

  test('startup unprotect failure never grants network admission or clears saved data', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.login();
      final protected = h.domain.state.syncSecrets.protectedAccess!.toList();
      h.owner.dispose();
      h.secrets.failUnprotect = true;
      h.owner = h.newOwner();
      var failed = false;
      h.owner.restoreSession().then<void>(
        (_) => fail('unexpected'),
        onError: (Object _) {
          failed = true;
        },
      );
      clock.flushMicrotasks();
      expect(failed, isTrue);
      expect(h.owner.view.phase, SyncAuthPhase.error);
      expect(h.domain.state.syncSecrets.protectedAccess, protected);
      expect(h.count('/v1/token/refresh'), 0);
      expect(h.owner.view.errorCode, 'PROTECTION_UNAVAILABLE');
      h.close();
    });
  });
  test('no account needs no network; approval stores only protected tokens before signed-in', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.owner.restoreSession();
      clock.flushMicrotasks();
      expect(h.http.requests, isEmpty);
      expect(h.owner.view.phase, SyncAuthPhase.disabled);
      h.begin();
      expect(h.owner.view.userCode, 'ABCDEFGHJK');
      expect(h.browser.pages.single.queryParameters.keys, ['user_code']);
      expect(h.count('/v1/device-token'), 0);
      clock.elapse(const Duration(seconds: 4));
      expect(h.count('/v1/device-token'), 0);
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      expect(h.domain.state.syncState.enabled, isTrue);
      expect(h.owner.view.accountId, wire.id(1));
      expect(h.domain.state.syncSecrets.protectedAccess, [1]);
      expect(h.domain.state.syncSecrets.protectedRefresh, [2]);
      expect(h.domain.state.syncSecrets.protectedStatusProof, [3]);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      expect(
        h.secrets.inputs.every((bytes) => bytes.every((byte) => byte == 0)),
        isTrue,
      );
      expect(
        h.secrets.outputs.every((bytes) => bytes.every((byte) => byte == 0)),
        isTrue,
      );
      expect(h.owner.view.userCode, isNull);
      expect(h.owner.view.activationUri, isNull);
      expect(h.count('/v1/vault/head'), 0);
      h.close();
    });
  });

  test('pending and slowdown use one sequential timer and expire without another request', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      var polls = 0;
      h.handler = (request) async => request.uri.path == '/v1/device-token'
          ? remote(++polls == 1 ? 'slow_down' : 'authorization_pending')
          : null;
      h.begin();
      clock.elapse(const Duration(seconds: 5));
      clock.flushMicrotasks();
      expect(polls, 1);
      clock.elapse(const Duration(seconds: 9));
      expect(polls, 1);
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(polls, 2);
      expect(clock.nonPeriodicTimerCount, 1);
      clock.elapse(const Duration(seconds: 585));
      clock.flushMicrotasks();
      expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
      expect(h.owner.view.errorCode, 'expired_token');
      expect(h.domain.state.syncState.enabled, isFalse);
      expect(clock.nonPeriodicTimerCount, 0);
      h.close();
    });
  });

  test('denied token or lost successful response requires explicit new browser login', () {
    for (final lost in [false, true])
      fakeAsync((clock) {
        final h = Harness(clock);
        h.handler = (request) async {
          if (request.uri.path != '/v1/device-token') return null;
          if (lost) throw StateError('synthetic secret sentinel');
          return remote('access_denied');
        };
        h.begin();
        clock.elapse(const Duration(seconds: 5));
        clock.flushMicrotasks();
        expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
        clock.elapse(const Duration(minutes: 20));
        expect(h.count('/v1/device-token'), 1);
        expect(h.domain.state.syncState.enabled, isFalse);
        expect(h.owner.view.errorCode, isNot(contains('sentinel')));
        h.close();
      });
  });

  test(
    'cancel and pause prevent late auth response or protection from binding',
    () {
      for (final duringProtection in [false, true])
        fakeAsync((clock) {
          final h = Harness(clock);
          final response = Completer<SyncHttpResponse>();
          if (duringProtection)
            h.secrets.protecting = Completer<void>();
          else
            h.handler = (request) async =>
                request.uri.path == '/v1/device-token' ? response.future : null;
          h.begin();
          clock.elapse(const Duration(seconds: 5));
          clock.flushMicrotasks();
          h.owner.pause();
          if (duringProtection)
            h.secrets.protecting!.complete();
          else
            response.complete(wire.jsonResponse(wire.session()));
          clock.flushMicrotasks();
          expect(h.domain.state.syncState.enabled, isFalse);
          expect(h.domain.state.syncSecrets.protectedAccess, isNull);
          expect(h.owner.view.phase, SyncAuthPhase.paused);
          h.owner.resume();
          clock.flushMicrotasks();
          expect(h.owner.view.phase, SyncAuthPhase.disabled);
          h.close();
        });
    },
  );

  test('transaction guard prevents bind after cancellation during disk reservation', () {
    fakeAsync((clock) {
      final h = Harness(clock), free = Completer<int>();
      final repo = SyncRepository(
        h.domain,
        availableStorageBytes: () => free.future,
      );
      h.owner.dispose();
      h.owner = SyncOwner(
        repository: repo,
        secrets: h.secrets,
        browser: h.browser,
        transport: (origin) => SyncTransport(origin: origin, http: h.http),
        monotonicMicros: () => clock.elapsed.inMicroseconds,
      );
      h.begin();
      clock.elapse(const Duration(seconds: 5));
      clock.flushMicrotasks();
      expect(h.owner.view.phase, SyncAuthPhase.protecting);
      h.owner.cancelLogin();
      free.complete(100 * 1024 * 1024 * 1024);
      clock.flushMicrotasks();
      expect(h.domain.state.syncState.enabled, isFalse);
      expect(h.domain.state.syncSecrets.protectedAccess, isNull);
      h.close();
    });
  });

  test(
    'protection failure and failed persistence never expose signed-in state',
    () {
      for (final protect in [false, true])
        fakeAsync((clock) {
          final h = Harness(clock);
          if (protect)
            h.secrets.failProtect = true;
          else
            h.domain.failCommit = true;
          h.begin();
          clock.elapse(const Duration(seconds: 5));
          clock.flushMicrotasks();
          expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
          expect(h.domain.state.syncState.enabled, isFalse);
          expect(h.domain.state.syncSecrets.protectedAccess, isNull);
          h.close();
        });
    },
  );

  test('expired access refreshes once concurrently and persists rotation with proof/key preserved', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.login();
      h.domain.state.syncSecrets.protectedVaultRootKey = [99];
      clock.elapse(const Duration(seconds: 900));
      var completed = 0;
      for (var n = 0; n < 3; n++)
        h.owner.accessToken().then<void>((token) {
          expect(token.value, wire.token(5));
          completed++;
        });
      clock.flushMicrotasks();
      expect(completed, 3);
      expect(h.count('/v1/token/refresh'), 1);
      expect(h.domain.state.syncSecrets.protectedStatusProof, [3]);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, [99]);
      expect(h.domain.state.syncState.errorCode, isNull);
      h.close();
    });
  });

  test('401 token_expired retries action once after shared refresh; no refresh loop', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.login();
      var calls = 0;
      h.handler = (request) async =>
          request.uri.path == '/v1/vault/head' && ++calls == 1
          ? remote('token_expired', status: 401)
          : null;
      SyncHead? result;
      h.owner
          .withAccess(
            (transport, access, cancel) =>
                transport.head(access, vaultId: wire.id(3), cancel: cancel),
          )
          .then<void>((head) {
            result = head;
          });
      clock.flushMicrotasks();
      expect(result?.revision, 0);
      expect(calls, 2);
      expect(h.count('/v1/token/refresh'), 1);
      h.handler = (request) async => request.uri.path == '/v1/vault/head'
          ? remote('token_expired', status: 401)
          : null;
      var failed = false;
      h.owner
          .withAccess(
            (transport, access, cancel) =>
                transport.head(access, vaultId: wire.id(3), cancel: cancel),
          )
          .then<void>(
            (_) => fail('unexpected'),
            onError: (Object _) {
              failed = true;
            },
          );
      clock.flushMicrotasks();
      expect(failed, isTrue);
      expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
      expect(h.count('/v1/token/refresh'), 2);
      expect(h.count('/v1/device-status'), 1);
      h.close();
    });
  });

  test('lost refresh response clears admission and never replays even after owner restart', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.login();
      h.handler = (request) async {
        if (request.uri.path == '/v1/token/refresh') {
          expect(h.domain.state.syncState.errorCode, syncRefreshInFlight);
          throw StateError('lost');
        }
        return null;
      };
      clock.elapse(const Duration(seconds: 900));
      var failures = 0;
      h.owner.accessToken().then<void>(
        (_) => fail('unexpected'),
        onError: (Object _) {
          failures++;
        },
      );
      clock.flushMicrotasks();
      expect(failures, 1);
      expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
      expect(h.domain.state.syncSecrets.protectedRefresh, isNull);
      expect(h.domain.state.syncSecrets.protectedStatusProof, [3]);
      h.owner.dispose();
      h.owner = h.newOwner();
      h.owner.restoreSession();
      clock.flushMicrotasks();
      h.owner.accessToken().then<void>(
        (_) => fail('unexpected'),
        onError: (Object _) {
          failures++;
        },
      );
      clock.flushMicrotasks();
      expect(failures, 2);
      expect(h.count('/v1/token/refresh'), 1);
      h.close();
    });
  });

  test('durable refresh intent survives stopped owner and restart requires explicit login', () {
    fakeAsync((clock) {
      final h = Harness(clock);
      h.login();
      final pending = Completer<SyncHttpResponse>();
      h.handler = (request) async =>
          request.uri.path == '/v1/token/refresh' ? pending.future : null;
      clock.elapse(const Duration(seconds: 900));
      h.owner.accessToken().then<void>(
        (_) => fail('unexpected'),
        onError: (Object _) {},
      );
      clock.flushMicrotasks();
      expect(h.domain.state.syncState.errorCode, syncRefreshInFlight);
      h.owner.dispose();
      clock.flushMicrotasks();
      h.owner = h.newOwner();
      h.owner.restoreSession();
      clock.flushMicrotasks();
      expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
      expect(h.domain.state.syncState.errorCode, syncLoginRequired);
      pending.complete(h.refreshResponseForLateTest());
      clock.flushMicrotasks();
      expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
      expect(h.count('/v1/token/refresh'), 1);
      h.close();
    });
  });

  test('revoked/reset probe blocks old generation and clears vault key without deleting domain', () {
    for (final reset in [false, true])
      fakeAsync((clock) {
        final h = Harness(clock);
        h.login();
        h.domain.state.syncSecrets.protectedVaultRootKey = [99];
        final before = h.repository.capture();
        h.domain.state.profiles[wire.id(91)] = Profile()
          ..profileId = wire.id(91)
          ..displayName = 'Saved';
        h.handler = (request) async {
          if (request.uri.path == '/v1/vault/head')
            return remote('device_revoked', status: 403);
          if (request.uri.path == '/v1/device-status')
            return wire.jsonResponse({
              'status': reset ? 'vault_reset' : 'revoked',
            });
          return null;
        };
        h.owner
            .withAccess(
              (transport, access, cancel) =>
                  transport.head(access, vaultId: wire.id(3), cancel: cancel),
            )
            .then<void>((_) => fail('unexpected'), onError: (Object _) {});
        clock.flushMicrotasks();
        expect(
          h.owner.view.phase,
          reset ? SyncAuthPhase.vaultReset : SyncAuthPhase.revoked,
        );
        expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
        expect(h.domain.state.syncSecrets.protectedRefresh, isNull);
        expect(before.matches(h.domain.state.syncState), isFalse);
        expect(h.domain.state.profiles[wire.id(91)]?.displayName, 'Saved');
        expect(h.count('/v1/device-status'), 1);
        h.close();
      });
  });

  test('same account/vault reauthorization preserves dirty state; different account cannot replace it', () {
    for (final different in [false, true])
      fakeAsync((clock) {
        final h = Harness(clock);
        h.login();
        h.domain.state.syncState.syncGeneration = 7;
        h.repository.stageRoot(
          h.repository.capture(),
          rootId: wire.id(30),
          snapshotId: wire.id(31),
          revision: 1,
          sourceGeneration: 7,
          rootCiphertext: Uint8List(28),
          objects: [],
          pending: true,
          commitId: wire.id(32),
        );
        clock.flushMicrotasks();
        h.repository.blockAuthorization(
          h.repository.capture(),
          syncLoginRequired,
        );
        clock.flushMicrotasks();
        h.owner.dispose();
        h.owner = h.newOwner();
        h.handler = (request) async => request.uri.path == '/v1/device-token'
            ? wire.jsonResponse({
                ...wire.session(),
                'device_id': wire.id(77),
                'account_id': different ? wire.id(88) : wire.id(1),
              })
            : null;
        h.begin();
        clock.elapse(const Duration(seconds: 5));
        clock.flushMicrotasks();
        expect(h.domain.state.syncState.accountId, wire.id(1));
        expect(h.domain.state.syncState.syncGeneration, 7);
        expect(h.domain.state.syncState.pendingRootId, wire.id(30));
        expect(h.domain.state.syncRoots[wire.id(30)]?.role, 'pending');
        expect(
          h.domain.state.syncState.deviceId,
          different ? wire.id(2) : wire.id(77),
        );
        expect(
          h.owner.view.phase,
          different ? SyncAuthPhase.loginRequired : SyncAuthPhase.signedIn,
        );
        h.close();
      });
  });

  test('local protected binding rejects another origin/account/device/vault/role and wipes buffers', () async {
    final port = SecretPort(), box = SyncSecretBox(SecretPort());
    final bound = SyncSecretBox(port);
    SyncIdentity identity({
      String service = 'https://sync.test',
      int account = 1,
      int device = 2,
      int vault = 3,
    }) => SyncIdentity(
      serviceOrigin: service,
      accountId: wire.id(account),
      deviceId: wire.id(device),
      vaultId: wire.id(vault),
    );
    final protected = await bound.protectText(
      identity(),
      SyncLocalSecretKind.access,
      wire.token(1),
    );
    expect(
      await bound.unprotectText(
        identity(),
        SyncLocalSecretKind.access,
        protected,
      ),
      wire.token(1),
    );
    for (final other in [
      identity(service: 'https://other.test'),
      identity(account: 9),
      identity(device: 9),
      identity(vault: 9),
    ]) {
      await expectLater(
        bound.unprotectText(other, SyncLocalSecretKind.access, protected),
        throwsA(isA<OperationFailure>()),
      );
    }
    await expectLater(
      bound.unprotectText(identity(), SyncLocalSecretKind.refresh, protected),
      throwsA(isA<OperationFailure>()),
    );
    expect(
      bound.purpose(identity(), SyncLocalSecretKind.access).length,
      lessThanOrEqualTo(128),
    );
    expect(
      bound.purpose(identity(), SyncLocalSecretKind.vaultKey),
      bound.purpose(identity(device: 99), SyncLocalSecretKind.vaultKey),
    );
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final wrapped = await bound.protectVaultKey(identity(), key);
    final unwrapped = await bound.unprotectVaultKey(
      identity(device: 99),
      wrapped,
    );
    expect(unwrapped, key);
    unwrapped.fillRange(0, 32, 0);
    expect(
      port.inputs.every((bytes) => bytes.every((byte) => byte == 0)),
      isTrue,
    );
    expect(
      box.purpose(identity(), SyncLocalSecretKind.statusProof),
      isNot(bound.purpose(identity(), SyncLocalSecretKind.access)),
    );
  });
}

extension on Harness {
  SyncHttpResponse refreshResponseForLateTest() => wire.jsonResponse({
    'access_token': wire.token(5),
    'refresh_token': wire.token(6),
    'expires_in': 900,
  });
}
