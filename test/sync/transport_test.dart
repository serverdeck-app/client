import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_http.dart';
import 'package:serverdeck/sync/sync_json.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_transport.dart';
import 'package:serverdeck/sync/sync_wire.dart';

String id(int n) => '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
final origin = SyncServiceOrigin('https://sync.test');
String token(int n) =>
    base64Url.encode(Uint8List(32)..[0] = n).replaceAll('=', '');
SyncBoundSecret secret(SyncSecretKind kind, {SyncServiceOrigin? service}) =>
    SyncBoundSecret(
      origin: service ?? origin,
      kind: kind,
      value: kind == SyncSecretKind.statusProof
          ? 'opaque.proof.synthetic'
          : token(1),
    );
final access = secret(SyncSecretKind.access);
final invalid = throwsA(
  isA<OperationFailure>().having(
    (error) => error.code,
    'code',
    FailureCode.invalidArgument,
  ),
);
Map<String, Object?> authorization() => {
  'device_code': token(2),
  'user_code': 'ABCDEFGHJK',
  'verification_uri': 'https://sync.test/activate',
  'verification_uri_complete':
      'https://sync.test/activate?user_code=ABCDEFGHJK',
  'expires_in': 600,
  'interval': 5,
};
Map<String, Object?> session() => {
  'account_id': id(1),
  'device_id': id(2),
  'vault_id': id(3),
  'email': 'test@example.test',
  'access_token': token(3),
  'refresh_token': token(4),
  'expires_in': 900,
  'status_proof': 'opaque.proof.synthetic',
};
Map<String, Object?> manifestMap({int revision = 1}) => {
  'version': 1,
  'content_version': 1,
  'vault_id': id(3),
  'snapshot_id': id(4),
  'revision': revision,
  'objects': [
    {'sha256': 'aa' * 32, 'bytes': 32},
  ],
  'root': {'sha256': 'bb' * 32, 'bytes': 256},
};
SyncHttpResponse jsonResponse(
  Object? value, {
  int status = 200,
  Map<String, List<String>>? headers,
}) => SyncHttpResponse(
  status,
  headers ??
      {
        'content-type': ['application/json; charset=utf-8'],
      },
  Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(value)))),
);

class Call implements SyncHttpCall {
  Call(this.response);
  @override
  final Future<SyncHttpResponse> response;
  bool cancelled = false;
  @override
  void cancel() {
    cancelled = true;
  }
}

class FakeHttp implements SyncHttpPort {
  FakeHttp(this.handler);
  final Future<SyncHttpResponse> Function(SyncHttpRequest, void Function())
  handler;
  final requests = <SyncHttpRequest>[];
  final calls = <Call>[];
  @override
  SyncHttpCall send(
    SyncHttpRequest request, {
    required void Function() onProgress,
  }) {
    requests.add(request);
    final call = Call(Future.sync(() => handler(request, onProgress)));
    calls.add(call);
    return call;
  }
}

void main() {
  test(
    'invalid Retry-After rejects before subscribing to any response body',
    () async {
      for (final (status, retry) in <(int, List<String>?)>[
        (200, ['5', '5']),
        (200, ['not-seconds']),
        (429, ['5', '5']),
        (429, ['bad']),
        (429, null),
        (503, null),
        (503, ['4']),
        (503, ['-5']),
        (503, ['9007199254740992']),
      ]) {
        var listened = false;
        final controller = StreamController<List<int>>(
          onListen: () {
            listened = true;
          },
        );
        final http = FakeHttp(
          (_, __) async => SyncHttpResponse(status, {
            'content-type': ['application/json'],
            if (retry != null) 'retry-after': retry,
          }, controller.stream),
        );
        final transport = SyncTransport(origin: origin, http: http);
        await expectLater(transport.head(access, vaultId: id(3)), invalid);
        expect(listened, isFalse, reason: '$status $retry');
        expect(http.calls.single.cancelled, isTrue);
        transport.dispose();
        // No subscription was created; close without awaiting a never-listened
        // controller's done future.
        unawaited(controller.close());
      }
    },
  );
  test('upload freezes caller bytes and wipes only its owned copy', () async {
    final pending = Completer<SyncHttpResponse>();
    final http = FakeHttp((_, __) => pending.future);
    final transport = SyncTransport(origin: origin, http: http);
    addTearDown(transport.dispose);
    final input = Uint8List.fromList([1, 2, 3]);
    final uploading = transport.upload(
      access,
      uploadId: id(5),
      ref: SyncBlobRef(syncSha256(input), input.length),
      ciphertext: input,
    );
    input.fillRange(0, input.length, 9);
    expect(http.requests.single.body, [1, 2, 3]);
    pending.complete(SyncHttpResponse(204, {}, const Stream.empty()));
    await uploading;
    expect(http.requests.single.body, [0, 0, 0]);
    expect(input, [9, 9, 9]);
  });
  test(
    'canonical HTTPS origin rejects ambiguous or noncanonical transport input',
    () {
      for (final value in [
        'http://sync.test',
        'https://u@sync.test',
        'https://sync.test/',
        'https://sync.test/x',
        'https://sync.test?',
        'https://sync.test#x',
        'https://SYNC.test',
        'https://sync.test:443',
        'https://sync.test:0',
        'https://sync.test:65536',
        'https://sync.test%2eevil',
        'https://sync.test\\evil',
        'https://sync.test\n',
      ]) {
        expect(() => SyncServiceOrigin(value), invalid, reason: value);
      }
      for (final value in [
        'https://sync.test',
        'https://127.0.0.1:444',
        'https://[::1]',
        'https://xn--bcher-kva.example',
      ]) {
        expect(SyncServiceOrigin(value).value, value);
      }
    },
  );

  test('typed device flow, token response, refresh and proof use exact bound paths', () async {
    final bodies = <Object?>[];
    final http = FakeHttp((request, _) async {
      bodies.add(
        request.body == null
            ? null
            : strictSyncJson(request.body!, maxBytes: 16384),
      );
      expect(request.uri.origin, origin.value);
      expect(request.headers['authorization'], isNull);
      return jsonResponse(switch (request.uri.path) {
        '/v1/device-authorizations' => authorization(),
        '/v1/device-token' => session(),
        '/v1/token/refresh' => {
          'access_token': token(5),
          'refresh_token': token(6),
          'expires_in': 900,
        },
        '/v1/device-status' => {'status': 'vault_reset'},
        _ => throw StateError('unexpected'),
      }, status: request.uri.path == '/v1/device-authorizations' ? 201 : 200);
    });
    final transport = SyncTransport(origin: origin, http: http);
    addTearDown(transport.dispose);
    final flow = await transport.beginDevice(
      platform: 'android',
      name: ' Phone ',
    );
    expect(flow.userCode, 'ABCDEFGHJK');
    final issued = await transport.pollDevice(flow.deviceCode);
    expect(issued.accountId, id(1));
    expect(issued.tokens.access.origin.value, origin.value);
    final refreshed = await transport.refresh(issued.tokens.refresh);
    expect(refreshed.access.value, token(5));
    expect(
      await transport.status(issued.statusProof),
      SyncDeviceStatus.vaultReset,
    );
    expect(bodies, [
      {'platform': 'android', 'device_name': 'Phone'},
      {'device_code': token(2)},
      {'refresh_token': token(4)},
      {'status_proof': 'opaque.proof.synthetic'},
    ]);
    for (final request in http.requests) {
      expect(request.body!.every((byte) => byte == 0), isTrue);
      expect(request.headers['accept-encoding'], 'identity');
    }
    expect(http.calls.every((call) => call.cancelled), isTrue);
  });

  test(
    'no secret can cross origin or be used in another credential role',
    () async {
      final http = FakeHttp((_, __) async => throw StateError('must not send'));
      final transport = SyncTransport(origin: origin, http: http);
      addTearDown(transport.dispose);
      final other = SyncServiceOrigin('https://other.test');
      await expectLater(
        transport.head(
          secret(SyncSecretKind.access, service: other),
          vaultId: id(3),
        ),
        invalid,
      );
      await expectLater(
        transport.pollDevice(secret(SyncSecretKind.deviceCode, service: other)),
        invalid,
      );
      await expectLater(
        transport.refresh(secret(SyncSecretKind.refresh, service: other)),
        invalid,
      );
      await expectLater(
        transport.status(secret(SyncSecretKind.statusProof, service: other)),
        invalid,
      );
      await expectLater(
        transport.head(secret(SyncSecretKind.refresh), vaultId: id(3)),
        invalid,
      );
      expect(http.requests, isEmpty);
    },
  );

  test(
    'browser device URI must be exact origin/activate and user code only',
    () async {
      for (final patch in [
        {'verification_uri': 'https://evil.test/activate'},
        {
          'verification_uri_complete':
              'https://sync.test/activate?user_code=ABCDEFGHJK&token=secret',
        },
        {
          'verification_uri_complete':
              'https://sync.test/activate?user_code=ZZZZZZZZZZ',
        },
        {'device_code': 'bad'},
        {'interval': 1},
        {'expires_in': 601},
        {'unknown': 'secret'},
      ]) {
        final http = FakeHttp(
          (_, __) async =>
              jsonResponse({...authorization(), ...patch}, status: 201),
        );
        final transport = SyncTransport(origin: origin, http: http);
        addTearDown(transport.dispose);
        await expectLater(
          transport.beginDevice(platform: 'windows', name: 'Desktop'),
          invalid,
        );
      }
    },
  );

  test(
    'head/manifest strict versions, namespace, projection/count/size/revision',
    () async {
      final manifest = SyncManifest.parse(manifestMap());
      expect(manifest.toJson(), manifestMap());
      for (final patch in [
        {'revision': 0},
        {'vault_id': 'not-uuid'},
        {'extra': 1},
        {
          'objects': [
            {'sha256': 'bb' * 32, 'bytes': 32},
          ],
        },
        {
          'objects': [
            {'sha256': 'cc' * 32, 'bytes': 32},
            {'sha256': 'aa' * 32, 'bytes': 32},
          ],
        },
        {
          'objects': [
            {'sha256': 'aa' * 32, 'bytes': 32},
            {'sha256': 'aa' * 32, 'bytes': 32},
          ],
        },
        {
          'objects': List.filled(11001, {'sha256': 'aa' * 32, 'bytes': 32}),
        },
        {
          'root': {'sha256': 'bb' * 32, 'bytes': syncMaxRootBytes + 1},
        },
      ]) {
        expect(() => SyncManifest.parse({...manifestMap(), ...patch}), invalid);
      }
      expect(
        () => SyncManifest.parse({...manifestMap(), 'content_version': 2}),
        throwsA(isA<SyncUnsupportedContentVersion>()),
      );
      final http = FakeHttp(
        (_, __) async => jsonResponse({
          'vault_id': id(3),
          'revision': 1,
          'manifest': manifestMap(),
        }),
      );
      final transport = SyncTransport(origin: origin, http: http);
      addTearDown(transport.dispose);
      expect((await transport.head(access, vaultId: id(3))).revision, 1);
      await expectLater(transport.head(access, vaultId: id(99)), invalid);
      for (final data in [
        {'vault_id': id(3), 'revision': 0, 'manifest': manifestMap()},
        {'vault_id': id(3), 'revision': 1, 'manifest': null},
        {'vault_id': id(3), 'revision': 2, 'manifest': manifestMap()},
      ]) {
        expect(() => SyncHead.parse(data, vaultId: id(3)), invalid);
      }
      expect(
        SyncHead.parse({
          'vault_id': id(3),
          'revision': 0,
          'manifest': null,
        }, vaultId: id(3)).manifest,
        isNull,
      );
    },
  );

  test('upload declaration, immutable blob, commit, download and cancellation wire', () async {
    final ciphertext = Uint8List.fromList([1, 2, 3, 4]);
    final ref = SyncBlobRef(syncSha256(ciphertext), ciphertext.length);
    final manifest = SyncManifest.parse({
      ...manifestMap(),
      'objects': [
        {'sha256': ref.sha256, 'bytes': ref.bytes},
      ],
    });
    final http = FakeHttp((request, progress) async {
      expect(request.headers['authorization'], 'Bearer ${access.value}');
      if (request.method == 'PUT') {
        expect(request.body, ciphertext);
        expect(request.headers['content-type'], 'application/octet-stream');
        progress();
        return SyncHttpResponse(204, {}, const Stream.empty());
      }
      if (request.method == 'GET') {
        expect(request.uri.query, 'revision=1');
        return SyncHttpResponse(
          200,
          {
            'content-type': ['application/octet-stream'],
            'content-length': ['4'],
          },
          Stream.fromIterable([
            ciphertext.sublist(0, 2),
            ciphertext.sublist(2),
          ]),
        );
      }
      if (request.method == 'DELETE')
        return SyncHttpResponse(204, {}, const Stream.empty());
      final body =
          strictSyncJson(request.body!, maxBytes: syncMaxRootBytes + 512)!
              as Map;
      if (request.uri.path.endsWith('/commit')) {
        expect(body, {'commit_id': id(6)});
        return jsonResponse({
          'vault_id': id(3),
          'snapshot_id': id(4),
          'revision': 1,
          'commit_id': id(6),
        });
      }
      expect(body, {
        'upload_id': id(5),
        'expected_revision': 0,
        'manifest': manifest.toJson(),
      });
      return jsonResponse({
        'upload_id': id(5),
        'expires_at': 100000,
        'missing': [ref.sha256],
      }, status: 201);
    });
    final transport = SyncTransport(origin: origin, http: http);
    addTearDown(transport.dispose);
    expect(
      (await transport.declare(
        access,
        uploadId: id(5),
        expectedRevision: 0,
        manifest: manifest,
      )).missing,
      [ref.sha256],
    );
    await transport.upload(
      access,
      uploadId: id(5),
      ref: ref,
      ciphertext: ciphertext,
    );
    expect(ciphertext, [1, 2, 3, 4]);
    expect(
      (await transport.commit(
        access,
        uploadId: id(5),
        commitId: id(6),
        manifest: manifest,
      )).commitId,
      id(6),
    );
    expect(await transport.download(access, ref: ref, revision: 1), ciphertext);
    await transport.cancelUpload(access, id(5));
    expect(http.requests.length, 5);
    await expectLater(
      transport.upload(
        access,
        uploadId: id(5),
        ref: ref,
        ciphertext: Uint8List(4),
      ),
      invalid,
    );
    await expectLater(
      transport.declare(
        access,
        uploadId: id(5),
        expectedRevision: 2,
        manifest: manifest,
      ),
      invalid,
    );
    expect(http.requests.length, 5);
  });

  test(
    'typed errors preserve known retry/CAS/status, never raw response text',
    () async {
      for (final (status, code, extra, headers) in [
        (
          400,
          'authorization_pending',
          <String, Object?>{},
          <String, List<String>>{},
        ),
        (400, 'slow_down', <String, Object?>{}, <String, List<String>>{}),
        (401, 'token_expired', <String, Object?>{}, <String, List<String>>{}),
        (403, 'refresh_reused', <String, Object?>{}, <String, List<String>>{}),
        (
          409,
          'revision_conflict',
          <String, Object?>{'vault_id': id(3), 'revision': 8},
          <String, List<String>>{},
        ),
        (
          503,
          'storage_busy',
          <String, Object?>{'retry_after_seconds': 20},
          <String, List<String>>{
            'retry-after': ['30'],
          },
        ),
        (
          429,
          'rate_limited',
          <String, Object?>{},
          <String, List<String>>{
            'retry-after': ['5'],
          },
        ),
      ]) {
        final http = FakeHttp(
          (_, __) async => jsonResponse(
            {'error': code, 'request_id': id(9), ...extra},
            status: status,
            headers: {
              'content-type': ['application/json'],
              ...headers,
            },
          ),
        );
        final transport = SyncTransport(origin: origin, http: http);
        addTearDown(transport.dispose);
        await expectLater(
          transport.pollDevice(secret(SyncSecretKind.deviceCode)),
          throwsA(
            isA<SyncRemoteFailure>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.status, 'status', status),
          ),
        );
      }
      for (final value in [
        {'error': 'secret sentinel', 'request_id': id(9)},
        {'error': 'rate_limited', 'request_id': 'secret sentinel'},
        {
          'error': 'token_expired',
          'request_id': id(9),
          'extra': 'secret sentinel',
        },
      ]) {
        expect(() => SyncRemoteFailure.parse(429, value, '5'), invalid);
      }
      expect(
        SyncRemoteFailure.parse(503, {
          'error': 'storage_busy',
          'request_id': id(9),
          'retry_after_seconds': 20,
        }, '30').retryAfterSeconds,
        30,
      );
    },
  );

  test(
    'duplicate headers, compression, media, lengths and redirects rejected',
    () async {
      for (final response in [
        jsonResponse(
          {},
          headers: {
            'content-type': ['application/json', 'application/json'],
          },
        ),
        jsonResponse(
          {},
          headers: {
            'Content-Type': ['application/json'],
            'content-type': ['application/json'],
          },
        ),
        jsonResponse(
          {},
          headers: {
            'content-type': ['application/json'],
            'content-encoding': ['gzip'],
          },
        ),
        jsonResponse(
          {},
          headers: {
            'content-type': ['text/html'],
          },
        ),
        jsonResponse(
          {},
          headers: {
            'content-type': ['application/json'],
            'content-length': ['1', '1'],
          },
        ),
        jsonResponse(
          {},
          headers: {
            'content-type': ['application/json'],
            'content-length': ['9999999'],
          },
        ),
        jsonResponse(
          {},
          headers: {
            'content-type': ['application/json'],
            'content-length': ['-1'],
          },
        ),
        jsonResponse(
          {},
          headers: {
            'content-type': ['application/json'],
            'content-length': ['1'],
          },
        ),
        jsonResponse(
          {},
          status: 302,
          headers: {
            'content-type': ['application/json'],
            'location': ['https://evil.test'],
          },
        ),
      ]) {
        final http = FakeHttp((_, __) async => response);
        final transport = SyncTransport(origin: origin, http: http);
        addTearDown(transport.dispose);
        await expectLater(transport.head(access, vaultId: id(3)), invalid);
        expect(http.requests.length, 1);
        expect(http.calls.single.cancelled, isTrue);
      }
    },
  );

  test('stream limits stop on first extra byte; incomplete/hash-changed blob rejects', () async {
    var delivered = 0;
    Stream<List<int>> oversized() async* {
      delivered++;
      yield Uint8List(16384);
      delivered++;
      yield [1];
      delivered++;
      yield [2];
    }

    final http = FakeHttp(
      (_, __) async => SyncHttpResponse(200, {
        'content-type': ['application/json'],
      }, oversized()),
    );
    final transport = SyncTransport(origin: origin, http: http);
    addTearDown(transport.dispose);
    await expectLater(
      transport.pollDevice(secret(SyncSecretKind.deviceCode)),
      invalid,
    );
    expect(delivered, 2);
    for (final bytes in [
      [1, 2],
      [1, 2, 3, 5],
    ]) {
      final binary = FakeHttp(
        (_, __) async => SyncHttpResponse(200, {
          'content-type': ['application/octet-stream'],
        }, Stream.value(bytes)),
      );
      final client = SyncTransport(origin: origin, http: binary);
      addTearDown(client.dispose);
      await expectLater(
        client.download(
          access,
          ref: SyncBlobRef(syncSha256([1, 2, 3, 4]), 4),
          revision: 1,
        ),
        invalid,
      );
    }
  });

  test(
    'metadata deadline includes body; blob timer resets only with progress',
    () {
      fakeAsync((clock) {
        final controller = StreamController<List<int>>();
        var cancelled = false;
        controller.onCancel = () {
          cancelled = true;
        };
        final http = FakeHttp(
          (_, __) async => SyncHttpResponse(200, {
            'content-type': ['application/json'],
          }, controller.stream),
        );
        final transport = SyncTransport(origin: origin, http: http);
        var timedOut = false;
        transport
            .pollDevice(secret(SyncSecretKind.deviceCode))
            .then<void>(
              (_) => fail('unexpected success'),
              onError: (Object e) {
                expect(
                  e,
                  isA<OperationFailure>().having(
                    (e) => e.code,
                    'code',
                    FailureCode.timeout,
                  ),
                );
                timedOut = true;
              },
            );
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 29));
        controller.add([123]);
        clock.flushMicrotasks();
        expect(timedOut, isFalse);
        clock.elapse(const Duration(seconds: 1));
        clock.flushMicrotasks();
        expect(timedOut, isTrue);
        expect(cancelled, isTrue);
        transport.dispose();
        controller.close();
        clock.flushMicrotasks();

        final stream = StreamController<List<int>>();
        final bodyHttp = FakeHttp(
          (_, __) async => SyncHttpResponse(200, {
            'content-type': ['application/octet-stream'],
          }, stream.stream),
        );
        final binary = SyncTransport(origin: origin, http: bodyHttp);
        Uint8List? received;
        binary
            .download(
              access,
              ref: SyncBlobRef(syncSha256([1, 2, 3]), 3),
              revision: 1,
            )
            .then((value) {
              received = value;
            });
        clock.flushMicrotasks();
        for (final byte in [1, 2, 3]) {
          clock.elapse(const Duration(seconds: 59));
          stream.add([byte]);
          clock.flushMicrotasks();
        }
        stream.close();
        clock.flushMicrotasks();
        expect(received, [1, 2, 3]);
        binary.dispose();
        expect(clock.nonPeriodicTimerCount, 0);
      });
    },
  );

  test(
    'cancel before send, during headers/body and dispose reject late responses',
    () {
      fakeAsync((clock) {
        final pending = Completer<SyncHttpResponse>();
        final http = FakeHttp((_, __) => pending.future);
        final transport = SyncTransport(origin: origin, http: http);
        var errors = 0;
        void error(Object e) {
          expect(e, isA<SyncTransportCancelled>());
          errors++;
        }

        final pre = SyncCancellation()..cancel();
        transport
            .head(access, vaultId: id(3), cancel: pre)
            .then<void>((_) => fail('unexpected'), onError: error);
        clock.flushMicrotasks();
        expect(errors, 1);
        expect(http.requests, isEmpty);
        final cancel = SyncCancellation();
        transport
            .head(access, vaultId: id(3), cancel: cancel)
            .then<void>((_) => fail('unexpected'), onError: error);
        clock.flushMicrotasks();
        cancel.cancel();
        clock.flushMicrotasks();
        expect(errors, 2);
        expect(http.calls.single.cancelled, isTrue);
        pending.complete(
          jsonResponse({'vault_id': id(3), 'revision': 0, 'manifest': null}),
        );
        clock.flushMicrotasks();
        expect(errors, 2);
        final body = StreamController<List<int>>();
        final bodyHttp = FakeHttp(
          (_, __) async => SyncHttpResponse(200, {
            'content-type': ['application/json'],
          }, body.stream),
        );
        final other = SyncTransport(origin: origin, http: bodyHttp);
        other
            .head(access, vaultId: id(3))
            .then<void>((_) => fail('unexpected'), onError: error);
        clock.flushMicrotasks();
        other.dispose();
        clock.flushMicrotasks();
        expect(errors, 3);
        body.close();
        clock.flushMicrotasks();
        other
            .head(access, vaultId: id(3))
            .then<void>((_) => fail('unexpected'), onError: error);
        clock.flushMicrotasks();
        expect(errors, 4);
        transport.dispose();
        expect(clock.nonPeriodicTimerCount, 0);
      });
    },
  );

  test(
    'device list, logout and own-revoke preserve typed actions and no bodies',
    () async {
      final http = FakeHttp((request, _) async {
        if (request.method == 'GET')
          return jsonResponse({
            'devices': [
              {
                'id': id(2),
                'name': 'Phone',
                'platform': 'android',
                'last_seen_at': 1000,
              },
            ],
          });
        expect(request.body, isNull);
        return SyncHttpResponse(204, {}, const Stream.empty());
      });
      final transport = SyncTransport(origin: origin, http: http);
      addTearDown(transport.dispose);
      expect((await transport.devices(access)).single.name, 'Phone');
      await transport.logout(access);
      await transport.revokeSelf(access, id(2));
      expect(http.requests.map((r) => r.uri.path), [
        '/v1/devices',
        '/v1/logout',
        '/v1/devices/${id(2)}/revoke',
      ]);
      expect(() => SyncWire.deviceName('Hidden\u200b'), invalid);
      expect(
        () => SyncUploadDeclaration.parse(
          {
            'upload_id': id(5),
            'expires_at': 10,
            'missing': ['cc' * 32],
          },
          id(5),
          SyncManifest.parse(manifestMap()),
        ),
        invalid,
      );
      expect(
        () => SyncCommitReceipt.parse(
          {
            'vault_id': id(3),
            'snapshot_id': id(4),
            'revision': 2,
            'commit_id': id(6),
          },
          id(6),
          SyncManifest.parse(manifestMap()),
        ),
        invalid,
      );
    },
  );

  test('duplicate/float JSON and future wire version reject; network errors sanitized', () async {
    for (final text in [
      '{"status":"active","status":"revoked"}',
      '{"status":1.0}',
      '{"status":"active","unknown":1}',
    ]) {
      final http = FakeHttp(
        (_, __) async => SyncHttpResponse(200, {
          'content-type': ['application/json'],
        }, Stream.value(utf8.encode(text))),
      );
      final transport = SyncTransport(origin: origin, http: http);
      addTearDown(transport.dispose);
      await expectLater(
        transport.status(secret(SyncSecretKind.statusProof)),
        invalid,
      );
    }
    final futureHttp = FakeHttp(
      (_, __) async => jsonResponse({
        'vault_id': id(3),
        'revision': 1,
        'manifest': {...manifestMap(), 'version': 2},
      }),
    );
    final futureTransport = SyncTransport(origin: origin, http: futureHttp);
    addTearDown(futureTransport.dispose);
    await expectLater(
      futureTransport.head(access, vaultId: id(3)),
      throwsA(isA<SyncUnsupportedContentVersion>()),
    );
    final badHttp = FakeHttp(
      (_, __) async => throw const HandshakeException('secret sentinel'),
    );
    final badTransport = SyncTransport(origin: origin, http: badHttp);
    addTearDown(badTransport.dispose);
    try {
      await badTransport.head(access, vaultId: id(3));
      fail('unexpected');
    } catch (e) {
      expect(
        e,
        isA<OperationFailure>().having(
          (e) => e.code,
          'code',
          FailureCode.networkError,
        ),
      );
      expect(e.toString(), isNot(contains('secret sentinel')));
    }
    final refs = List.generate(
      1024,
      (i) => {
        'sha256': i.toRadixString(16).padLeft(64, '0'),
        'bytes': syncMaxObjectBytes,
      },
    );
    expect(
      () => SyncManifest.parse({...manifestMap(), 'objects': refs}),
      invalid,
    );
  });

  test('upload inactivity resets with written progress and times out after silence', () {
    fakeAsync((clock) {
      late void Function() progress;
      final pending = Completer<SyncHttpResponse>();
      final http = FakeHttp((_, callback) {
        progress = callback;
        return pending.future;
      });
      final transport = SyncTransport(origin: origin, http: http);
      final bytes = Uint8List.fromList([1, 2, 3]);
      var timeout = false;
      transport
          .upload(
            access,
            uploadId: id(5),
            ref: SyncBlobRef(syncSha256(bytes), 3),
            ciphertext: bytes,
          )
          .then<void>(
            (_) => fail('unexpected'),
            onError: (Object e) {
              expect(
                e,
                isA<OperationFailure>().having(
                  (e) => e.code,
                  'code',
                  FailureCode.timeout,
                ),
              );
              timeout = true;
            },
          );
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 59));
      progress();
      clock.elapse(const Duration(seconds: 59));
      expect(timeout, isFalse);
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(timeout, isTrue);
      expect(http.calls.single.cancelled, isTrue);
      pending.complete(SyncHttpResponse(204, {}, const Stream.empty()));
      clock.flushMicrotasks();
      transport.dispose();
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test(
    'native cancel during pending open aborts late socket before any body',
    () async {
      final native = DelayedNativeClient();
      final port = DartSyncHttpPort(createClient: () => native);
      final call = port.send(
        SyncHttpRequest(
          'POST',
          Uri.parse('https://sync.test/v1/device-token'),
          {},
          Uint8List.fromList([1]),
        ),
        onProgress: () {},
      );
      call.cancel();
      native.pending.complete(native.request);
      await expectLater(call.response, invalid);
      expect(native.request.aborted, isTrue);
      expect(native.request.sent, isEmpty);
      expect(native.forced, isTrue);
    },
  );

  test(
    'native HTTP adapter disables redirects/decompression and force closes',
    () async {
      final native = FakeNativeClient();
      final port = DartSyncHttpPort(createClient: () => native);
      final call = port.send(
        SyncHttpRequest(
          'POST',
          Uri.parse('https://sync.test/v1/device-token'),
          {'content-type': 'application/json'},
          Uint8List.fromList([1, 2, 3]),
        ),
        onProgress: () {},
      );
      expect((await call.response).status, 204);
      expect(native.autoUncompressValue, isFalse);
      expect(native.request.redirects, isFalse);
      expect(native.request.redirectLimit, 0);
      expect(native.request.contentLengthValue, 3);
      expect(native.request.sent, [1, 2, 3]);
      call.cancel();
      call.cancel();
      expect(native.forced, isTrue);
    },
  );
}

class FakeNativeClient implements HttpClient {
  final request = FakeNativeRequest();
  bool? autoUncompressValue, forced;
  @override
  set autoUncompress(bool value) {
    autoUncompressValue = value;
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async => request;
  @override
  void close({bool force = false}) {
    forced = force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DelayedNativeClient extends FakeNativeClient {
  final pending = Completer<HttpClientRequest>();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => pending.future;
}

class FakeNativeRequest implements HttpClientRequest {
  bool aborted = false;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
  }

  bool? redirects;
  int? redirectLimit, contentLengthValue;
  final sent = <int>[];
  @override
  final headers = FakeNativeHeaders();
  @override
  set followRedirects(bool value) {
    redirects = value;
  }

  @override
  set maxRedirects(int value) {
    redirectLimit = value;
  }

  @override
  set persistentConnection(bool value) {}
  @override
  set contentLength(int value) {
    contentLengthValue = value;
  }

  @override
  void add(List<int> data) {
    sent.addAll(data);
  }

  @override
  Future<void> flush() async {}
  @override
  Future<HttpClientResponse> close() async => FakeNativeResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeNativeHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void forEach(void Function(String, List<String>) action) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeNativeResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  int get statusCode => 204;
  @override
  final headers = FakeNativeHeaders();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const Stream<List<int>>.empty().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
