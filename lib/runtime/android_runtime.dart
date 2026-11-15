import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/mutation_receipts.dart';
import '../storage/domain_repository.dart';
import '../storage/store_manifest.dart';
import 'android_platform.dart';
import 'android_workspace.dart';
import 'capability.dart';
import 'feature_runtime.dart';
import 'native_platform.dart';
import 'platform_ports.dart';

/// Adapts shared runtime readiness/cleanup to Android Activity ownership.
/// Unsupported desktop commands are never exposed in mobile routes.
final class AndroidRuntimePlatform implements RuntimePlatform {
  AndroidRuntimePlatform(this.platform) {
    _subscription = platform.changes.listen((phase) {
      if (phase == PlatformLifecyclePhase.detached) {
        _events.add(PlatformEvent(platform.epoch, ++_seq, 'osSessionEnding'));
      }
    });
  }
  final AndroidPlatform platform;
  final _release = ValueNotifier<String?>(null);
  final _events = StreamController<PlatformEvent>.broadcast();
  late final StreamSubscription<PlatformLifecyclePhase> _subscription;
  int _seq = 0;
  bool _finished = false;
  @override
  ValueListenable<String?> get release => _release;
  @override
  Stream<PlatformEvent> get events => _events.stream;
  @override
  Future<PlatformSnapshot> snapshot({String? runtimeState}) async {
    final context = await platform.initialize();
    return PlatformSnapshot(
      epoch: context.epoch,
      seq: _seq,
      window: platform.phase == PlatformLifecyclePhase.resumed
          ? WindowState.visible
          : WindowState.minimized,
      trayAvailable: false,
      osEnding: platform.phase == PlatformLifecyclePhase.detached,
    );
  }

  @override
  Future<bool> hideToTray() => throw UnsupportedError('Tray unavailable');
  @override
  Future<bool> restore() =>
      throw UnsupportedError('Window activation unavailable');
  @override
  Future<bool> retryTray() => throw UnsupportedError('Tray unavailable');
  @override
  Future<bool> requestUpdateRestart(String version) =>
      throw UnsupportedError('Desktop updates unavailable');
  @override
  Future<void> closeActivation() => _subscription.cancel();
  @override
  Future<void> finishExit() async {
    if (_finished) return;
    _finished = true;
    unawaited(_events.close());
    _release.dispose();
  }
}

/// Root-owned shared owner graph over the sole AndroidWorkspace store.
final class AndroidApplicationWorkspace
    implements RuntimeStore, RuntimeCapability {
  AndroidApplicationWorkspace(this.platform) {
    workspace = AndroidWorkspace(
      storage: platform,
      secrets: platform,
      disposePlatform: platform.dispose,
    );
  }
  final AndroidPlatform platform;
  late final AndroidWorkspace workspace;
  FeatureRuntime? features;
  bool Function() isRunning = () => false;
  Future<void>? _opening;
  bool _stopped = false;
  @override
  String get id => 'android-workspace-features';
  @override
  String get theme => workspace.theme;
  @override
  Future<void> open() =>
      _opening ??= _open().whenComplete(() => _opening = null);
  Future<void> _open() async {
    if (_stopped) throw const StoreFailure('SHUTTING_DOWN');
    await workspace.open();
    if (_stopped) return;
    if (features == null) {
      final repository = WorkspaceDomainRepository(workspace.store);
      final cipher = Uint8List.fromList(
        repository.read((r) => r.security.protectedReceiptHmacKey),
      );
      Uint8List? key;
      var installed = false;
      try {
        key = await platform.unprotect(cipher, 'receipt-hmac.v1');
        if (_stopped) return;
        features = FeatureRuntime.android(
          secrets: platform,
          keyPicker: platform,
          ownerEpoch: platform.epoch,
          dataRoot: workspace.store.dataRoot,
          repository: repository,
          signer: ReceiptSigner(key),
          isRunning: isRunning,
        );
        features!.configureSync(
          browser: platform,
          availableStorageBytes: platform.availableStorageBytes,
          monotonicMicros: platform.monotonicMicros,
          lifecycle: platform,
          refreshClock: platform.refreshMonotonicClock,
        );
        installed = true;
      } finally {
        cipher.fillRange(0, cipher.length, 0);
        key?.fillRange(0, key.length, 0);
        if (!installed) repository.disposeNotifications();
      }
    }
    if (!_stopped) await features!.initialize();
  }

  @override
  Future<void> stopAdmission() async {
    _stopped = true;
    workspace.stopAdmission();
    await features?.stopAdmission();
  }

  @override
  Future<void> finishWrites() => workspace.finishWrites();
  @override
  Future<void> cancelPending() async => await features?.cancelPending();
  @override
  Future<void> closeSessions() async => await features?.closeSessions();
  @override
  Future<void> drain() async {
    try {
      await _opening;
    } catch (_) {
      /* root retains startup error */
    }
    await features?.drain();
  }

  @override
  Future<void> dispose() async => await features?.dispose();
  @override
  Future<void> close() async {
    await features?.dispose();
    await workspace.close();
  }
}
