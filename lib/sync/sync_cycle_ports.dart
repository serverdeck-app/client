import 'dart:typed_data';

import 'sync_models.dart';
import 'sync_recovery.dart';
import 'sync_transport.dart';
import 'sync_wire.dart';

/// Native authenticated I/O only. Implemented by the auth owner; no plaintext,
/// token or arbitrary-origin capability reaches the cycle/publication owner.
abstract interface class SyncCycleAccess implements SyncVaultAccess {
  Future<Uint8List> readVaultBlob(
    SyncVaultContext context,
    SyncManifest manifest,
    SyncBlobRef ref,
    SyncCancellation cancel,
  );
  Future<SyncUploadDeclaration> declareVaultUpload(
    SyncVaultContext context,
    String uploadId,
    SyncManifest manifest,
    SyncCancellation cancel,
  );
  Future<void> uploadVaultBlob(
    SyncVaultContext context,
    String uploadId,
    SyncBlobRef ref,
    Uint8List bytes,
    SyncCancellation cancel,
  );
  Future<SyncCommitReceipt> commitVaultUpload(
    SyncVaultContext context,
    String uploadId,
    String commitId,
    SyncManifest manifest,
    SyncCancellation cancel,
  );
  Future<void> cancelVaultUpload(
    SyncVaultContext context,
    String uploadId,
    SyncCancellation cancel,
  );
}
