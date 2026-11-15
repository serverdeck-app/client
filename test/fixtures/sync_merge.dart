import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:serverdeck/sync/sync_apply.dart';
import 'package:serverdeck/sync/sync_crypto.dart';
import 'package:serverdeck/sync/sync_json.dart';
import 'package:serverdeck/sync/sync_merge.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_recovery.dart';
import 'package:serverdeck/sync/sync_transport.dart';
import 'package:serverdeck/sync/sync_wire.dart';

import '../sync/content_validation_test.dart' as content;
import '../sync/credential_transfer_test.dart' as transfer;

String mergeId(int n) => content.id(n);
PortableSyncProfile mergeProfile(
  int n, {
  String name = 'Server',
  int? credential,
  int updated = 2,
}) {
  final value = content.profile(number: n, credential: credential);
  (value['profile']! as Map)['displayName'] = name;
  (value['profile']! as Map)['updatedAt'] = updated;
  return PortableSyncProfile.parse(value);
}

PortableSyncCard mergeCard(int n, int owner, {String name = 'Service'}) {
  final value = content.card(number: n, owner: owner);
  (value['card']! as Map)['name'] = name;
  return PortableSyncCard.parse(value);
}

class MergeAccess implements SyncVaultAccess {
  MergeAccess(this.root, this.context);
  final transfer.Harness root;
  final SyncVaultContext context;
  late SyncHead head;
  Completer<void>? gate;
  int reads = 0, cancelledReads = 0;
  bool live = true;
  @override
  void guardVaultContext(SyncVaultContext context) {
    if (!live || !context.fence.matches(root.domain.state.syncState))
      throw const SyncTransportCancelled();
  }

  @override
  bool isVaultContextCurrent(SyncVaultContext context) => live;
  @override
  Future<SyncVaultContext> vaultContext() async => context;
  @override
  Future<Uint8List> readVaultRoot(
    SyncVaultContext context,
    SyncManifest manifest,
    SyncCancellation cancel,
  ) => throw UnimplementedError();
  @override
  Future<SyncHead> readVaultHead(
    SyncVaultContext context,
    SyncCancellation cancel,
  ) async {
    guardVaultContext(context);
    reads++;
    final stopped = Completer<SyncHead>();
    final remove = cancel.listen(() {
      cancelledReads++;
      if (!stopped.isCompleted)
        stopped.completeError(const SyncTransportCancelled());
    });
    try {
      final result = () async {
        if (gate != null) await gate!.future;
        return head;
      }();
      return await Future.any([result, stopped.future]);
    } finally {
      remove();
    }
  }
}

class MergeHarness {
  final root = transfer.Harness();
  late final MergeAccess access;
  late final SyncMergeController controller;
  bool ready = true;
  int serial = 0;
  Future<void> setup() async {
    await root.setup();
    access = MergeAccess(root, root.access.context);
    access.head = SyncHead.parse({
      'vault_id': root.fence.identity.vaultId,
      'revision': 0,
      'manifest': null,
    }, vaultId: root.fence.identity.vaultId);
    controller = SyncMergeController(
      repository: root.domain,
      access: access,
      keyReady: () => ready,
    );
  }

  SyncCredentialProof? proof(PortableSyncContent value) =>
      value is PortableSyncProfile
      ? value.credentialKind == 'password'
            ? SyncCredentialProof.password
            : SyncCredentialProof.encryptedLegacyMetadataOnly
      : null;
  SyncMergeSnapshot local(List<PortableSyncContent> values) {
    final builder = SyncMergeSnapshotBuilder.local(root.snapshot);
    for (final value in values) {
      try {
        builder.add(value, proof: proof(value));
      } finally {
        value.dispose();
      }
    }
    return builder.finish();
  }

  SyncMergeSnapshot remote(
    List<PortableSyncContent> values, {
    int revision = 1,
    bool current = true,
  }) {
    final salt = ++serial;
    // Structural, synthetic opaque refs: this helper tests merge/index logic,
    // not a downloadable candidate. Crypto/content authentication has own units.
    final refs =
        values.map((value) {
            final bytes = canonicalSyncJson(value.toJson());
            try {
              return SyncRootEntry(
                kind: value.kind,
                id: value.id,
                sha256: syncSha256(
                  utf8.encode('$salt/${value.kind}/${value.id}'),
                ),
                bytes: bytes.length + 28,
              );
            } finally {
              bytes.fillRange(0, bytes.length, 0);
            }
          }).toList()
          ..sort((a, b) => '${a.kind}/${a.id}'.compareTo('${b.kind}/${b.id}'));
    final crypto = SyncCrypto(
      identity: root.fence.identity,
      rootKey: Uint8List(32),
    );
    late final SyncEncryptedRoot encrypted;
    try {
      encrypted = crypto.encryptRoot(
        snapshotId: mergeId(100000 + salt),
        revision: revision,
        entries: refs,
      );
    } finally {
      crypto.dispose();
    }
    final manifest = SyncManifest.parse({
      'version': 1,
      'content_version': 1,
      'vault_id': root.fence.identity.vaultId,
      'snapshot_id': encrypted.root.snapshotId,
      'revision': revision,
      'objects': encrypted.objects
          .map((ref) => {'sha256': ref.sha256, 'bytes': ref.bytes})
          .toList(),
      'root': {'sha256': encrypted.ref.sha256, 'bytes': encrypted.ref.bytes},
    });
    final builder = SyncMergeSnapshotBuilder.remote(
      access.context,
      encrypted.root,
      manifest,
    );
    final byId = {for (final ref in refs) '${ref.kind}/${ref.id}': ref};
    for (final value in values) {
      try {
        builder.add(
          value,
          encryptedRef: byId['${value.kind}/${value.id}'],
          proof: proof(value),
        );
      } finally {
        value.dispose();
      }
    }
    if (current)
      access.head = SyncHead.parse({
        'vault_id': manifest.vaultId,
        'revision': revision,
        'manifest': manifest.toJson(),
      }, vaultId: manifest.vaultId);
    return builder.finish();
  }

  SyncMergeSnapshot emptyRemote() {
    access.head = SyncHead.parse({
      'vault_id': root.fence.identity.vaultId,
      'revision': 0,
      'manifest': null,
    }, vaultId: root.fence.identity.vaultId);
    return SyncMergeSnapshotBuilder.emptyRemote(access.context).finish();
  }
}
