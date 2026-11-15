import 'dart:async';
import 'dart:typed_data';

import 'package:serverdeck/sync/sync_wire.dart';

import 'package:serverdeck/runtime/platform_ports.dart';
import 'package:serverdeck/storage/records.dart';
import 'package:serverdeck/sync/sync_http.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/sync/sync_secret_box.dart';
import 'package:serverdeck/sync/sync_transport.dart';

import 'sync_apply.dart';
import 'feature_harness.dart';
import '../sync/device_auth_test.dart' as auth;
import '../sync/transport_test.dart' as wire;

class LifecycleBrowser implements PlatformBrowserPort {
  final pages = <(Uri, Uri)>[];
  FutureOr<void> Function()? onOpen;
  @override
  Future<void> openServicePage({
    required Uri serviceOrigin,
    required Uri page,
  }) async {
    pages.add((serviceOrigin, page));
    await onOpen?.call();
  }
}

class LifecycleHarness {
  final local = ApplyHarness();
  final secrets = auth.SecretPort();
  final browser = LifecycleBrowser();
  late SyncOwner owner;
  late SyncAccountLifecycle lifecycle;
  late wire.FakeHttp http;
  Future<SyncHttpResponse?> Function(SyncHttpRequest)? handler;
  String status = 'active';
  String? nextAccount, nextVault, nextDevice;
  final devices = <Object?>[];
  Future<void> setup() async {
    await local.setup();
    http = wire.FakeHttp((request, _) async {
      final custom = handler;
      if (custom != null) {
        final response = await custom(request);
        if (response != null) return response;
      }
      final origin = request.uri.origin;
      return switch (request.uri.path) {
        '/v1/logout' => SyncHttpResponse(204, const {}, const Stream.empty()),
        '/v1/token/refresh' => wire.jsonResponse({
          'access_token': wire.token(5),
          'refresh_token': wire.token(6),
          'expires_in': 900,
        }),
        '/v1/device-status' => wire.jsonResponse({'status': status}),
        '/v1/vault/head' => wire.jsonResponse({
          'vault_id': nextVault ?? local.fence.identity.vaultId,
          'revision': 0,
          'manifest': null,
        }),
        '/v1/devices' => wire.jsonResponse({'devices': devices}),
        '/v1/device-authorizations' => wire.jsonResponse({
          ...wire.authorization(),
          'verification_uri': '$origin/activate',
          'verification_uri_complete': '$origin/activate?user_code=ABCDEFGHJK',
        }, status: 201),
        '/v1/device-token' => wire.jsonResponse({
          ...wire.session(),
          'account_id': nextAccount ?? local.fence.identity.accountId,
          'vault_id': nextVault ?? local.fence.identity.vaultId,
          'device_id': nextDevice ?? featureId(8100),
          'access_token': wire.token(7),
          'refresh_token': wire.token(8),
        }),
        _ =>
          request.uri.path.endsWith('/revoke')
              ? SyncHttpResponse(204, const {}, const Stream.empty())
              : throw StateError('unexpected synthetic URI'),
      };
    });
    owner = makeOwner();
    final identity = local.fence.identity;
    final access = await owner.box.protectText(
      identity,
      SyncLocalSecretKind.access,
      wire.token(3),
    );
    final refresh = await owner.box.protectText(
      identity,
      SyncLocalSecretKind.refresh,
      wire.token(4),
    );
    final proof = await owner.box.protectText(
      identity,
      SyncLocalSecretKind.statusProof,
      'opaque.proof.synthetic',
    );
    final key = await owner.box.protectVaultKey(identity, Uint8List(32));
    await local.feature.repository.write(
      (r) => r.putSyncSecrets(
        SyncSecretRecord()
          ..protectedAccess = [...access]
          ..protectedRefresh = [...refresh]
          ..protectedStatusProof = [...proof]
          ..protectedVaultRootKey = [...key],
      ),
    );
    access.fillRange(0, access.length, 0);
    refresh.fillRange(0, refresh.length, 0);
    proof.fillRange(0, proof.length, 0);
    key.fillRange(0, key.length, 0);
    await owner.restoreSession();
    lifecycle = owner.configureLifecycle(
      gate: local.feature.gate,
      actor: local.feature.actors.owner,
      connections: local.batches,
    );
  }

  SyncOwner makeOwner() => SyncOwner(
    repository: local.repository,
    secrets: secrets,
    browser: browser,
    transport: (origin) => SyncTransport(origin: origin, http: http),
    monotonicMicros: () => local.feature.clock.elapsed.inMicroseconds,
    authPollSchedule: local.feature.clock.schedule,
    recoveryRandomBytes: (length) =>
        Uint8List.fromList(List.generate(length, (i) => (i + 5) % 256)),
  );
  int count(String path) =>
      http.requests.where((r) => r.uri.path == path).length;
  Future<void> login({
    String? account,
    String? vault,
    String? device,
    SyncServiceOrigin? origin,
  }) async {
    nextAccount = account;
    nextVault = vault;
    nextDevice = device;
    await owner.beginLogin(
      origin:
          origin ??
          SyncServiceOrigin(
            local.feature.repository.state.syncState.serviceOrigin!,
          ),
      platform: 'windows',
      name: 'Next',
    );
    local.feature.clock.advance(const Duration(seconds: 5));
    for (var i = 0; i < 40 && owner.view.phase != SyncAuthPhase.signedIn; i++) {
      await featureTurns(1);
    }
    if (owner.view.phase != SyncAuthPhase.signedIn)
      throw StateError('synthetic login did not settle');
  }

  Future<void> recreate() async {
    await owner.cycle?.dispose();
    await lifecycle.dispose();
    owner.dispose();
    await featureTurns();
    owner = makeOwner();
    await owner.restoreSession();
    lifecycle = owner.configureLifecycle(
      gate: local.feature.gate,
      actor: local.feature.actors.owner,
      connections: local.batches,
    );
  }

  Future<void> dispose() async {
    await owner.cycle?.dispose();
    await lifecycle.dispose();
    owner.dispose();
    await local.dispose();
  }
}
