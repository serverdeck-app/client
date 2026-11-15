import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/src/ssh_message.dart';
import 'package:serverdeck/sync/sync_cycle.dart';
import 'package:serverdeck/sync/sync_merge.dart';
import 'package:serverdeck/sync/sync_models.dart';

import 'sync_merge.dart';
import '../sync/content_validation_test.dart' as data;

class CycleActionsFake implements SyncCycleActions {
  CycleActionsFake(this.view);
  @override
  SyncCycleView view;
  final stream = StreamController<SyncCycleView>.broadcast();
  @override
  Stream<SyncCycleView> get changes => stream.stream;
  int retries = 0, cancels = 0;
  final confirmations = <(SyncMergePreview, SyncMergeChoice)>[];
  Future<void> Function()? onRetry, onConfirm;
  void emit(SyncCycleView next) {
    view = next;
    stream.add(next);
  }

  @override
  Future<void> retry() async {
    retries++;
    await onRetry?.call();
  }

  @override
  Future<void> confirm(SyncMergePreview preview, SyncMergeChoice choice) async {
    confirmations.add((preview, choice));
    if (onConfirm != null) {
      await onConfirm!();
    } else {
      emit(const SyncCycleView(SyncCyclePhase.synced));
    }
  }

  @override
  void cancelPreview() {
    cancels++;
    emit(
      const SyncCycleView(
        SyncCyclePhase.consent,
        errorCode: 'CONSENT_CANCELLED',
      ),
    );
  }

  Future<void> dispose() => stream.close();
}

/// Vetted projection shapes for functional UI tests, not credential validation.
Future<SyncMergePreview> uiPreview({
  int conflicts = 0,
  bool legacy = false,
  bool missingBase = false,
}) async {
  final h = MergeHarness();
  await h.setup();
  if (missingBase) h.root.domain.state.syncState.baseRevision = 1;
  PortableSyncProfile profile(int n, String label) {
    final value = data.profile(number: n);
    (value['profile']! as Map)['displayName'] = label;
    (value['credential']! as Map)['originalBase64'] = base64.encode(
      utf8.encode('credential-private-sentinel'),
    );
    if (legacy) {
      final writer = SSHMessageWriter()
        ..writeUtf8('ssh-ed25519')
        ..writeString(Uint8List.fromList(List.filled(32, 7)));
      (value['credential']! as Map<String, Object?>).addAll({
        'kind': 'privateKey',
        'publicKeyType': 'ssh-ed25519',
        'publicKeyBits': 256,
        'publicKeyBase64': base64.encode(writer.takeBytes()),
      });
    }
    return PortableSyncProfile.parse(value);
  }

  final local = h.local([
    for (var i = 0; i < (conflicts == 0 ? 1 : conflicts); i++)
      profile(10 + i * 2, 'private-local-name'),
  ]);
  final remote = h.remote(
    conflicts == 0
        ? [profile(100, 'private-remote-name'), mergeCard(200, 100)]
        : [
            for (var i = 0; i < conflicts; i++)
              profile(10 + i * 2, 'private-remote-name'),
          ],
  );
  try {
    return await h.controller.propose(local: local, remote: remote);
  } finally {
    h.controller.dispose();
  }
}
