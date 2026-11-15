import '../domain/actor.dart';
import '../domain/app_operations.dart';

/// Root-only bulk mutation admission. Not available through AppOperations/MCP.
abstract interface class ProfileBatchPort {
  /// Complete affected IDs: existing profiles carry exact profileRevision; new
  /// IDs carry null. Caller supplies recomputed target endpoints and a synchronous
  /// identity/data/key guard. All arguments are copied before gate admission.
  Future<ProfileMutationBatch> reserveProfileBatch(
    OwnerActor actor, {
    required Map<String, int?> expectedProfiles,
    required Set<String> targetEndpoints,
    required void Function() guard,
  });
}

abstract interface class ProfileMutationBatch {
  /// Invalidations happen at reservation. Close runs outside the command gate.
  Future<void> close();

  /// Check inside the final guarded transaction before its first domain write.
  /// Requires the same OwnerActor context and confirmed close of this batch.
  void check(CommandContext context);

  /// Idempotent cleanup; no domain writes or revival of cancelled sessions.
  void release();
}
