import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/storage/records.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_http.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/sync/sync_repository.dart';
import 'package:serverdeck/sync/sync_transport.dart';

import '../fixtures/sync_handoff.dart';
import 'transport_test.dart' as wire;

void main() {
  test(
    'binding B during resumed token request drops only stale A approval',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      final response = Completer<SyncHttpResponse?>();
      h.handler = (r) => r.uri.path == '/v1/device-token'
          ? response.future
          : Future.value(null);
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      h.begin();
      h.resume();
      clock.elapse(const Duration(seconds: 5));
      h.repository.bind(
        expectedGeneration: 1,
        identity: SyncIdentity(
          serviceOrigin: 'https://other.test',
          accountId: wire.id(20),
          deviceId: wire.id(21),
          vaultId: wire.id(22),
        ),
        secrets: SyncSecretRecord()
          ..protectedAccess = [1]
          ..protectedRefresh = [2]
          ..protectedStatusProof = [3],
      );
      clock.flushMicrotasks();
      response.complete(wire.jsonResponse(wire.session()));
      clock.flushMicrotasks();
      expect(h.owner.hasPendingLogin, isFalse);
      expect(h.domain.state.syncState.accountId, wire.id(20));
      expect(h.domain.state.syncSecrets.protectedAccess, [1]);
      clock.elapse(const Duration(seconds: 20));
      expect(h.count('/v1/device-token'), 1);
      expect(h.timers, 0);
      h.dispose();
    }),
  );
  for (final reason in [syncDeviceRevoked, syncVaultReset]) {
    for (final duringPoll in [false, true]) {
      test(
        'changed $reason ${duringPoll ? "during" : "before"} resumed poll clears approval',
        () => fakeAsync((clock) {
          final h = HandoffHarness(clock);
          h.begin();
          clock.elapse(const Duration(seconds: 5));
          final response = Completer<SyncHttpResponse?>();
          h.handler = (r) => r.uri.path == '/v1/device-token'
              ? response.future
              : Future.value(null);
          h.browser.onOpen = () =>
              h.owner.pause(preserveDeviceAuthorization: true);
          h.begin();
          h.resume();
          if (duringPoll) clock.elapse(const Duration(seconds: 5));
          h.repository.blockAuthorization(h.repository.capture(), reason);
          clock.flushMicrotasks();
          if (duringPoll) {
            response.complete(wire.jsonResponse(wire.session()));
            clock.flushMicrotasks();
          } else {
            clock.elapse(const Duration(seconds: 5));
          }
          expect(h.owner.hasPendingLogin, isFalse);
          expect(
            h.owner.view.phase,
            reason == syncVaultReset
                ? SyncAuthPhase.vaultReset
                : SyncAuthPhase.revoked,
          );
          expect(h.timers, 0);
          clock.elapse(const Duration(seconds: 20));
          expect(h.count('/v1/device-token'), duringPoll ? 2 : 1);
          h.dispose();
        }),
      );
    }
  }
  test(
    'browser pause retains only pending Android flow and resumes one eligible poll',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      h.begin();
      expect(h.owner.view.phase, SyncAuthPhase.paused);
      expect(h.owner.hasPendingLogin, isTrue);
      expect(h.owner.view.userCode, isNull);
      expect(h.domain.state.syncSecrets.protectedAccess, isNull);
      clock.elapse(const Duration(seconds: 100));
      expect(h.count('/v1/device-token'), 0);
      expect(h.timers, 0);
      h.resume();
      clock.elapse(Duration.zero);
      clock.flushMicrotasks();
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      expect(h.browser.pages.length, 1);
      expect(h.count('/v1/device-authorizations'), 1);
      expect(h.count('/v1/device-token'), 1);
      expect(h.owner.hasPendingLogin, isFalse);
      expect(h.errors, isEmpty);
      h.dispose();
    }),
  );
  test(
    'pending browser completion cannot arm polling before five seconds after successful open',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      h.browser.hold = Completer<void>();
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      h.begin();
      h.resume();
      clock.elapse(const Duration(seconds: 10));
      expect(h.count('/v1/device-token'), 0);
      expect(h.timers, 0);
      h.browser.hold!.complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 4));
      expect(h.count('/v1/device-token'), 0);
      clock.elapse(const Duration(seconds: 1));
      expect(h.count('/v1/device-token'), 1);
      expect(h.errors, isEmpty);
      h.dispose();
    }),
  );
  test(
    'original600second expiry includes paused time and never restarts approval',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      h.begin();
      clock.elapse(const Duration(seconds: 600));
      h.resume();
      clock.elapse(Duration.zero);
      expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
      expect(h.owner.view.errorCode, 'expired_token');
      expect(h.owner.hasPendingLogin, isFalse);
      expect(h.count('/v1/device-token'), 0);
      expect(h.browser.pages.length, 1);
      expect(h.timers, 0);
      h.dispose();
    }),
  );
  test(
    'slow_down interval survives foreground suspension without a paused timer',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      var polls = 0;
      h.handler = (r) async => r.uri.path == '/v1/device-token' && polls++ == 0
          ? wire.jsonResponse({
              'error': 'slow_down',
              'request_id': wire.id(90),
            }, status: 400)
          : null;
      h.begin();
      clock.elapse(const Duration(seconds: 5));
      expect(h.count('/v1/device-token'), 1);
      h.owner.pause(preserveDeviceAuthorization: true);
      clock.elapse(const Duration(seconds: 3));
      expect(h.timers, 0);
      h.resume();
      clock.elapse(const Duration(seconds: 6));
      expect(h.count('/v1/device-token'), 1);
      clock.elapse(const Duration(seconds: 1));
      expect(h.count('/v1/device-token'), 2);
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      h.dispose();
    }),
  );
  test(
    'pause during uncertain token request drops flow and cannot retry consumed code',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      final reply = Completer<SyncHttpResponse>();
      h.handler = (r) async =>
          r.uri.path == '/v1/device-token' ? reply.future : null;
      h.begin();
      clock.elapse(const Duration(seconds: 5));
      expect(h.count('/v1/device-token'), 1);
      h.owner.pause(preserveDeviceAuthorization: true);
      expect(h.owner.hasPendingLogin, isFalse);
      h.resume();
      reply.complete(wire.jsonResponse(wire.session()));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 60));
      expect(h.domain.state.syncState.enabled, isFalse);
      expect(h.domain.state.syncSecrets.protectedAccess, isNull);
      expect(h.count('/v1/device-token'), 1);
      expect(h.timers, 0);
      h.dispose();
    }),
  );
  test(
    'protection after received token is not a resumable approval flow',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      h.secrets.protecting = Completer<void>();
      h.begin();
      clock.elapse(const Duration(seconds: 5));
      expect(h.owner.view.phase, SyncAuthPhase.protecting);
      h.owner.pause(preserveDeviceAuthorization: true);
      expect(h.owner.hasPendingLogin, isFalse);
      h.secrets.protecting!.complete();
      clock.flushMicrotasks();
      h.resume();
      expect(h.domain.state.syncState.enabled, isFalse);
      expect(h.domain.state.syncSecrets.protectedAccess, isNull);
      expect(h.count('/v1/device-token'), 1);
      h.dispose();
    }),
  );
  test(
    'cancel while suspended invalidates late browser success and no resume poll appears',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      h.browser.hold = Completer<void>();
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      h.begin();
      h.owner.cancelLogin();
      h.resume();
      h.browser.hold!.complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 20));
      expect(h.owner.hasPendingLogin, isFalse);
      expect(h.count('/v1/device-token'), 0);
      expect(h.timers, 0);
      h.dispose();
    }),
  );
  test(
    'late browser failure after suspension requires explicit new login',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      h.browser.hold = Completer<void>();
      h.browser.fail = true;
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      h.begin();
      h.resume();
      h.browser.hold!.complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 20));
      expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
      expect(h.owner.hasPendingLogin, isFalse);
      expect(h.count('/v1/device-token'), 0);
      expect(h.timers, 0);
      h.dispose();
    }),
  );
  test(
    'ordinary pause and Windows flow never opt into Android preservation',
    () => fakeAsync((clock) {
      for (final android in [false, true]) {
        final h = HandoffHarness(clock);
        h.begin(platform: android ? 'android' : 'windows');
        if (android) {
          h.owner.pause();
        } else {
          h.owner.pause(preserveDeviceAuthorization: true);
        }
        expect(h.owner.hasPendingLogin, isFalse);
        h.resume();
        clock.elapse(const Duration(seconds: 10));
        expect(h.count('/v1/device-token'), 0);
        h.dispose();
      }
    }),
  );
  test(
    'source identity changed while paused rejects old approval without touching B',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      h.begin();
      h.repository.bind(
        expectedGeneration: 1,
        identity: SyncIdentity(
          serviceOrigin: 'https://other.test',
          accountId: wire.id(20),
          deviceId: wire.id(21),
          vaultId: wire.id(22),
        ),
        secrets: SyncSecretRecord()
          ..protectedAccess = [1]
          ..protectedRefresh = [2]
          ..protectedStatusProof = [3],
      );
      clock.flushMicrotasks();
      final state = h.domain.state.syncSecrets.protectedAccess!.toList();
      h.resume();
      clock.elapse(const Duration(seconds: 10));
      expect(h.domain.state.syncState.accountId, wire.id(20));
      expect(h.domain.state.syncSecrets.protectedAccess, state);
      expect(h.owner.hasPendingLogin, isFalse);
      expect(h.count('/v1/device-token'), 0);
      h.dispose();
    }),
  );
  test(
    'rapid foreground epochs waiting on one browser acknowledgement arm only one poll',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      h.browser.hold = Completer<void>();
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      h.begin();
      var stale = false;
      h.owner.resume().then<void>(
        (_) {},
        onError: (Object _) {
          stale = true;
        },
      );
      clock.flushMicrotasks();
      h.owner.pause(preserveDeviceAuthorization: true);
      h.resume();
      h.browser.hold!.complete();
      clock.flushMicrotasks();
      expect(stale, isTrue);
      expect(h.timers, 1);
      clock.elapse(const Duration(seconds: 5));
      expect(h.count('/v1/device-token'), 1);
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      expect(h.browser.pages.length, 1);
      h.dispose();
    }),
  );
  test(
    'cancel also releases a foreground resume waiting for browser completion',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      h.browser.hold = Completer<void>();
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      h.begin();
      var cancelled = false;
      h.owner.resume().then<void>(
        (_) {},
        onError: (Object _) {
          cancelled = true;
        },
      );
      clock.flushMicrotasks();
      h.owner.cancelLogin();
      clock.flushMicrotasks();
      expect(cancelled, isTrue);
      h.browser.hold!.complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 10));
      expect(h.count('/v1/device-token'), 0);
      expect(h.timers, 0);
      expect(h.owner.hasPendingLogin, isFalse);
      h.dispose();
    }),
  );
  test(
    'late browser acknowledgement cannot extend original expiry for first poll',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      h.browser.hold = Completer<void>();
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      h.begin();
      clock.elapse(const Duration(seconds: 599));
      h.resume();
      h.browser.hold!.complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      expect(h.count('/v1/device-token'), 0);
      expect(h.owner.view.errorCode, 'expired_token');
      expect(h.owner.hasPendingLogin, isFalse);
      expect(h.timers, 0);
      h.dispose();
    }),
  );
  test(
    'bound reauthorization cannot restore old data access while approval is suspended',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      h.begin();
      clock.elapse(const Duration(seconds: 5));
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      final old = h.domain.state.syncSecrets.protectedAccess!.toList();
      h.handler = (r) async => r.uri.path == '/v1/device-token'
          ? wire.jsonResponse({...wire.session(), 'device_id': wire.id(44)})
          : null;
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      h.begin();
      h.resume();
      var denied = false;
      h.owner.accessToken().then<void>(
        (_) {},
        onError: (Object _) {
          denied = true;
        },
      );
      clock.flushMicrotasks();
      expect(denied, isTrue);
      expect(h.count('/v1/token/refresh'), 0);
      expect(h.domain.state.syncSecrets.protectedAccess, old);
      clock.elapse(const Duration(seconds: 5));
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      expect(h.owner.view.deviceId, wire.id(44));
      expect(h.count('/v1/device-token'), 2);
      h.dispose();
    }),
  );
  test(
    'revocation and vault reset during suspension replace old approval projection',
    () => fakeAsync((clock) {
      for (final reason in [syncDeviceRevoked, syncVaultReset]) {
        final h = HandoffHarness(clock);
        h.begin();
        clock.elapse(const Duration(seconds: 5));
        h.browser.onOpen = () =>
            h.owner.pause(preserveDeviceAuthorization: true);
        h.begin();
        h.repository.blockAuthorization(h.repository.capture(), reason);
        clock.flushMicrotasks();
        h.resume();
        clock.elapse(const Duration(seconds: 10));
        expect(h.owner.hasPendingLogin, isFalse);
        expect(
          h.owner.view.phase,
          reason == syncVaultReset
              ? SyncAuthPhase.vaultReset
              : SyncAuthPhase.revoked,
        );
        expect(h.count('/v1/device-token'), 1);
        expect(h.timers, 0);
        h.dispose();
      }
    }),
  );
  test(
    'no device authorization is restored in a new native owner process model',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      h.browser.hold = Completer<void>();
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      h.begin();
      h.owner.dispose();
      final replacement = SyncOwner(
        repository: h.repository,
        secrets: h.secrets,
        browser: HandoffBrowser(),
        transport: (origin) => SyncTransport(origin: origin, http: h.http),
        monotonicMicros: () => clock.elapsed.inMicroseconds,
      );
      replacement.restoreSession();
      clock.flushMicrotasks();
      h.browser.hold!.complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 10));
      expect(replacement.hasPendingLogin, isFalse);
      expect(replacement.view.phase, SyncAuthPhase.disabled);
      expect(h.count('/v1/device-token'), 0);
      expect(h.domain.state.syncSecrets.protectedAccess, isNull);
      replacement.dispose();
      clock.flushMicrotasks();
    }),
  );
  test(
    'clock failure before first authorization leaves retryable login state without HTTP',
    () => fakeAsync((clock) {
      final h = HandoffHarness(clock);
      final owner = SyncOwner(
        repository: h.repository,
        secrets: h.secrets,
        browser: h.browser,
        transport: (origin) => SyncTransport(origin: origin, http: h.http),
        monotonicMicros: () =>
            throw const OperationFailure(FailureCode.timeout),
      );
      var failed = false;
      owner
          .beginLogin(origin: wire.origin, platform: 'android', name: 'Phone')
          .then<void>(
            (_) {},
            onError: (Object _) {
              failed = true;
            },
          );
      clock.flushMicrotasks();
      expect(failed, isTrue);
      expect(owner.view.phase, SyncAuthPhase.loginRequired);
      expect(owner.view.errorCode, 'TIMEOUT');
      expect(h.http.requests, isEmpty);
      owner.dispose();
      h.dispose();
    }),
  );
}
