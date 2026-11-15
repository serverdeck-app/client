import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_http.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_origin.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/sync/sync_transport.dart';
import 'package:serverdeck/sync/sync_wire.dart';
import 'package:serverdeck/sync/sync_secret_box.dart';
import 'package:serverdeck/sync/sync_publication.dart';
import 'package:serverdeck/sync/sync_snapshots.dart';
import 'package:serverdeck/sync/sync_apply.dart';

import '../fixtures/feature_harness.dart';
import '../fixtures/sync_lifecycle.dart';
import 'transport_test.dart' as wire;

void main() {
  test(
    'canonical Unicode IDNA, DNS, IPv4, IPv6 and ports share one pure boundary',
    () {
      final cases = {
        ' HTTPS://Sync.Example.TEST:00443/ ': 'https://sync.example.test',
        'https://ПРИМЕР.РФ': 'https://xn--e1afmkfd.xn--p1ai',
        'https://bücher.example': 'https://xn--bcher-kva.example',
        'https://bu\u0308cher.example': 'https://xn--bcher-kva.example',
        'https://faß.example': 'https://fass.example',
        'https://ＥＸＡＭＰＬＥ．ｃｏｍ': 'https://example.com',
        'https://sync.example.test.:08443/': 'https://sync.example.test:8443',
        'https://192.0.2.1:65535': 'https://192.0.2.1:65535',
        'https://[2001:0DB8:0:0:0:0:0:1]:00443/': 'https://[2001:db8::1]',
        'https://localhost': 'https://localhost',
      };
      final longest = List.filled(3, 'a' * 63).join('.') + '.' + 'a' * 61;
      cases['https://$longest.'] = 'https://$longest';
      for (final entry in cases.entries) {
        final origin = normalizeSyncServiceOrigin(entry.key);
        expect(origin.value, entry.value, reason: entry.key);
        expect(normalizeSyncServiceOrigin(origin.value).value, entry.value);
      }
    },
  );

  test('ambiguous authorities, URL components and invalid Unicode never become origins', () {
    for (final value in [
      '',
      'http://sync.test',
      '//sync.test',
      'https:sync.test',
      'https://@sync.test',
      'https://user:pass@sync.test',
      'https://sync.test/path',
      'https://sync.test//',
      'https://sync.test?',
      'https://sync.test#',
      'https://sync%2etest',
      'https://sync.test:',
      'https://sync.test:0',
      'https://sync.test:65536',
      'https://sync.test:000443',
      'https://sync.test:+443',
      'https://a..test',
      'https://a.test..',
      'https://-a.test',
      'https://a-.test',
      'https://a_b.test',
      'https://127.1',
      'https://0177.0.0.1',
      'https://0x7f.0.0.1',
      'https://2130706433',
      'https://256.0.0.1',
      'https://2001:db8::1',
      'https://[::1]x',
      'https://[fe80::1%25eth0]',
      'https://sync\u200b.test',
      'https://sync\u00ad.test',
      'https://\ud800.test',
      'https://aא.test',
      'https://😀.test',
      'https://a b.test',
      'https://sync.test\n',
      'https://' + ('a' * 64) + '.test',
      'https://' + List.filled(5, 'a' * 63).join('.'),
      'https://' + 'a' * 2048,
    ]) {
      expect(
        () => normalizeSyncServiceOrigin(value),
        throwsA(isA<OperationFailure>()),
        reason: value,
      );
    }
  });
  test('durable/transport origin constructors reject ambiguous numeric authorities too', () {
    for (final host in [
      '127.1',
      '0177.0.0.1',
      '0x7f.0.0.1',
      '2130706433',
      '256.0.0.1',
    ]) {
      expect(
        () => SyncServiceOrigin('https://$host'),
        throwsA(isA<OperationFailure>()),
      );
    }
  });

  test(
    'bare hexadecimal zero browser hosts reject at input and strict boundaries',
    () {
      for (final host in [
        '0x',
        '0X',
        '127.0.0.0x',
        '0x.0x.0x.0x',
        'example.0x',
      ]) {
        expect(
          () => normalizeSyncServiceOrigin('https://$host'),
          throwsA(isA<OperationFailure>()),
          reason: host,
        );
        expect(
          () => SyncServiceOrigin('https://$host'),
          throwsA(isA<OperationFailure>()),
          reason: host,
        );
      }
    },
  );

  test('IDNA punctuation cannot synthesize bracketed or unbracketed IPv6 authority', () {
    for (final host in ['：：１', '［：：１］']) {
      expect(
        () => normalizeSyncServiceOrigin('https://$host'),
        throwsA(isA<OperationFailure>()),
        reason: host,
      );
    }
    expect(normalizeSyncServiceOrigin('https://[::1]').value, 'https://[::1]');
    expect(
      normalizeSyncServiceOrigin('https://ＢÜＣＨＥＲ.example').value,
      'https://xn--bcher-kva.example',
    );
  });

  group('origin-fenced native operations', () {
    late LifecycleHarness h;
    final next = SyncServiceOrigin('https://other.example.test:8443');
    setUp(() async {
      h = LifecycleHarness();
      await h.setup();
    });
    tearDown(() => h.dispose());
    Future<void> switchOrigin() async {
      await h.lifecycle.disconnect(await h.lifecycle.preview(nextOrigin: next));
      await h.login(
        origin: next,
        account: featureId(9500),
        vault: featureId(9501),
        device: featureId(9502),
      );
    }

    void noOldAuthorityAtNewOrigin(String oldAccess) {
      final requests = h.http.requests.where((r) => r.uri.origin == next.value);
      expect(requests, isNotEmpty);
      for (final request in requests) {
        expect(request.headers['authorization'], isNot('Bearer $oldAccess'));
        expect(
          request.uri.queryParameters.values,
          isNot(contains('opaque.proof.synthetic')),
        );
      }
    }

    test(
      'origin is part of token, proof and vault-key protection namespaces',
      () async {
        final old = h.local.fence.identity;
        final foreign = SyncIdentity(
          serviceOrigin: next.value,
          accountId: old.accountId,
          deviceId: old.deviceId,
          vaultId: old.vaultId,
        );
        for (final kind in [
          SyncLocalSecretKind.access,
          SyncLocalSecretKind.statusProof,
        ]) {
          final protected = await h.owner.box.protectText(
            old,
            kind,
            kind == SyncLocalSecretKind.access
                ? wire.token(3)
                : 'opaque.proof.synthetic',
          );
          await expectLater(
            h.owner.box.unprotectText(foreign, kind, protected),
            throwsA(isA<OperationFailure>()),
          );
          protected.fillRange(0, protected.length, 0);
        }
        final protected = await h.owner.box.protectVaultKey(old, Uint8List(32));
        await expectLater(
          h.owner.box.unprotectVaultKey(foreign, protected),
          throwsA(isA<OperationFailure>()),
        );
        protected.fillRange(0, protected.length, 0);
      },
    );

    test('bound origin cannot be silently replaced by login or merely previewing rebind', () async {
      final before = h
          .local
          .feature
          .repository
          .state
          .syncSecrets
          .protectedAccess!
          .toList();
      final generation =
          h.local.feature.repository.state.syncState.identityGeneration;
      final preview = await h.lifecycle.preview(nextOrigin: next);
      expect(preview.nextOrigin!.value, next.value);
      expect(h.http.requests, isEmpty);
      expect(
        h.local.feature.repository.state.syncSecrets.protectedAccess,
        before,
      );
      expect(
        h.local.feature.repository.state.syncState.identityGeneration,
        generation,
      );
      await expectLater(
        h.owner.beginLogin(origin: next, platform: 'android', name: 'New'),
        throwsA(isA<OperationFailure>()),
      );
      expect(h.http.requests, isEmpty);
      expect(
        h.local.feature.repository.state.syncState.serviceOrigin,
        h.local.fence.identity.serviceOrigin,
      );
    });

    test('failed rebind barrier cannot save new origin or claim cleared credentials', () async {
      final preview = await h.lifecycle.preview(nextOrigin: next);
      h.local.feature.repository.failCommit = true;
      await expectLater(
        h.lifecycle.disconnect(preview),
        throwsA(isA<OperationFailure>()),
      );
      final state = h.local.feature.repository.state;
      expect(
        state.syncState.serviceOrigin,
        h.local.fence.identity.serviceOrigin,
      );
      expect(state.syncSecrets.protectedAccess, isNotNull);
      expect(h.owner.view.phase, SyncAuthPhase.disconnectRequired);
      expect(h.http.requests, isEmpty);
    });

    test('device flow cancellation never polls old device code at new origin or binds late A', () async {
      await h.lifecycle.disconnect(await h.lifecycle.preview());
      final old = SyncServiceOrigin(h.local.fence.identity.serviceOrigin);
      final response = Completer<SyncHttpResponse>();
      final bodies = <(String, String)>[];
      h.handler = (r) async {
        if (r.uri.path == '/v1/device-authorizations' &&
            r.uri.origin == next.value) {
          return wire.jsonResponse({
            ...wire.authorization(),
            'device_code': wire.token(12),
            'verification_uri': '${next.value}/activate',
            'verification_uri_complete':
                '${next.value}/activate?user_code=ABCDEFGHJK',
          }, status: 201);
        }
        if (r.uri.path == '/v1/device-token') {
          bodies.add((
            r.uri.origin,
            (jsonDecode(utf8.decode(r.body!)) as Map)['device_code'] as String,
          ));
          if (r.uri.origin == old.value) return response.future;
        }
        return null;
      };
      await h.owner.beginLogin(origin: old, platform: 'windows', name: 'Old');
      h.local.feature.clock.advance(const Duration(seconds: 5));
      await featureTurns();
      expect(bodies, [(old.value, wire.token(2))]);
      h.owner.cancelLogin();
      await h.login(
        origin: next,
        account: featureId(9500),
        vault: featureId(9501),
        device: featureId(9502),
      );
      final protected = h
          .local
          .feature
          .repository
          .state
          .syncSecrets
          .protectedAccess!
          .toList();
      response.complete(wire.jsonResponse(wire.session()));
      await featureTurns();
      expect(bodies, [
        (old.value, wire.token(2)),
        (next.value, wire.token(12)),
      ]);
      expect(
        h.local.feature.repository.state.syncState.serviceOrigin,
        next.value,
      );
      expect(
        h.local.feature.repository.state.syncSecrets.protectedAccess,
        protected,
      );
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
    });

    test(
      'late old refresh cannot persist or send its tokens after rebind',
      () async {
        final response = Completer<SyncHttpResponse>();
        h.handler = (r) async =>
            r.uri.path == '/v1/token/refresh' && r.uri.origin != next.value
            ? response.future
            : null;
        final refresh = h.owner.accessToken();
        final rejected = expectLater(
          refresh,
          throwsA(isA<SyncTransportCancelled>()),
        );
        await featureTurns();
        await switchOrigin();
        final protected = h
            .local
            .feature
            .repository
            .state
            .syncSecrets
            .protectedAccess!
            .toList();
        response.complete(
          wire.jsonResponse({
            'access_token': wire.token(20),
            'refresh_token': wire.token(21),
            'expires_in': 900,
          }),
        );
        await rejected;
        await featureTurns();
        expect(
          h.local.feature.repository.state.syncSecrets.protectedAccess,
          protected,
        );
        noOldAuthorityAtNewOrigin(wire.token(3));
        expect(
          h.http.requests.where(
            (r) =>
                r.uri.origin == next.value && r.uri.path == '/v1/token/refresh',
          ),
          isEmpty,
        );
      },
    );

    test('late download from old origin cannot become a current candidate or return to caller', () async {
      final id = await h.local.feature.create();
      final pending = await h.local.remote([h.local.stored(id)], pending: true);
      final access = await h.owner.accessToken();
      final context = await h.owner.vaultContext();
      final encrypted = h.local.crypto.encryptRoot(
        snapshotId: featureId(9650),
        revision: 1,
        entries: const [],
      );
      final bytes = encrypted.envelope;
      final manifest = SyncManifest.parse({
        ...wire.manifestMap(),
        'vault_id': context.fence.identity.vaultId,
        'snapshot_id': encrypted.root.snapshotId,
        'objects': <Object?>[],
        'root': {'sha256': syncSha256(bytes), 'bytes': bytes.length},
      });
      final response = Completer<SyncHttpResponse>();
      h.handler = (r) async =>
          r.uri.path.contains('/blobs/') ? response.future : null;
      final transfer = SyncCredentialTransfer(
        repository: h.local.feature.repository,
        secrets: h.local.secrets,
        inspector: h.local.transfer.inspector,
        access: h.owner,
      );
      final reader = SyncSnapshotReader(
        repository: h.local.repository,
        transfer: transfer,
        access: h.owner,
        newId: h.local.feature.newId,
      );
      final head = SyncHead.parse({
        'vault_id': manifest.vaultId,
        'revision': manifest.revision,
        'manifest': manifest.toJson(),
      }, vaultId: manifest.vaultId);
      final download = reader.read(
        context,
        h.local.crypto,
        head,
        cancel: SyncCancellation(),
        isCurrent: () => h.owner.isVaultContextCurrent(context),
      );
      final rejected = expectLater(
        download,
        throwsA(isA<SyncTransportCancelled>()),
      );
      await featureTurns();
      expect(h.count('/v1/vault/blobs/${manifest.root.sha256}'), 1);
      await switchOrigin();
      response.complete(
        SyncHttpResponse(200, {
          'content-type': ['application/octet-stream'],
        }, Stream.value(bytes)),
      );
      await rejected;
      await featureTurns();
      final state = h.local.feature.repository.state;
      expect(state.syncState.candidateRootId, isNull);
      expect(state.syncRoots[pending.rootId]!.role, 'detached');
      expect(
        state.syncRoots[pending.rootId]!.serviceOrigin,
        h.local.fence.identity.serviceOrigin,
      );
      expect(state.profiles.keys, [id]);
      noOldAuthorityAtNewOrigin(access.value);
      bytes.fillRange(0, bytes.length, 0);
    });

    test('old successful commit receipt after new binding never ACKs detached intent', () async {
      final pending = await h.local.remote(const [], pending: true);
      final manifest = syncManifestForRoot(
        h.local.feature.repository.state.syncRoots[pending.rootId]!,
      );
      final commit =
          h.local.feature.repository.state.syncState.pendingCommitId!;
      final access = await h.owner.accessToken();
      final context = await h.owner.vaultContext();
      final response = Completer<SyncHttpResponse>();
      h.handler = (r) async =>
          r.uri.path.endsWith('/commit') ? response.future : null;
      final publisher = SyncPendingPublisher(
        repository: h.local.repository,
        access: h.owner,
        newId: h.local.feature.newId,
        utcNow: h.local.feature.clock.now,
      );
      final committing = publisher.publish(
        context,
        h.local.crypto,
        cancel: SyncCancellation(),
        isCurrent: () => h.owner.isVaultContextCurrent(context),
      );
      final rejected = expectLater(
        committing,
        throwsA(isA<SyncTransportCancelled>()),
      );
      await featureTurns();
      expect(h.count('/v1/vault/uploads/${pending.rootId}/commit'), 1);
      await switchOrigin();
      response.complete(
        wire.jsonResponse({
          'vault_id': manifest.vaultId,
          'snapshot_id': manifest.snapshotId,
          'revision': manifest.revision,
          'commit_id': commit,
        }),
      );
      await rejected;
      await featureTurns();
      final state = h.local.feature.repository.state;
      expect(state.syncState.baseRootId, isNull);
      expect(state.syncState.pendingRootId, isNull);
      expect(state.syncState.ackGeneration, 0);
      expect(state.syncRoots[pending.rootId]!.role, 'detached');
      expect(
        state.syncRoots[pending.rootId]!.serviceOrigin,
        h.local.fence.identity.serviceOrigin,
      );
      noOldAuthorityAtNewOrigin(access.value);
    });
  });
}
