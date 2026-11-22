import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../domain/models.dart' show isCanonicalUuid;
import '../storage/store_manifest.dart';
import '../sync/sync_wire.dart';
import 'platform_ports.dart';
import 'permission_lifecycle.dart';

const _secretLimit = 1024 * 1024;
const _protectedLimit = 2 * 1024 * 1024;
const _metadataLimit = 8192;

final class AndroidPlatformFailure implements Exception {
  const AndroidPlatformFailure(this.code);
  final String code;
  @override
  String toString() => code;
}

final class AndroidPlatformContext {
  const AndroidPlatformContext(this.epoch, this.dataRoot);
  final String epoch, dataRoot;
}

/// Native ports only. The workspace owner must close its store before dispose
/// releases the native workspace lease. Do not register this as an independent
/// runtime capability that could dispose before RuntimeStore.close.
final class AndroidPlatform
    with WidgetsBindingObserver
    implements
        PlatformCapabilityPort,
        PlatformSecretPort,
        PlatformKeyPickerPort,
        PlatformBrowserPort,
        PlatformStoragePort,
        PlatformLifecyclePort {
  AndroidPlatform({
    MethodChannel channel = const MethodChannel('serverdeck/android'),
    int Function()? awakeMicros,
    CameraPermissionGate? cameraPermissionGate,
  }) : _channel = channel,
       _cameraPermissionGate =
           cameraPermissionGate ?? CameraPermissionGate.shared {
    final clock = Stopwatch()..start();
    _awake = awakeMicros ?? (() => clock.elapsedMicroseconds);
  }
  final MethodChannel _channel;
  final CameraPermissionGate _cameraPermissionGate;
  void _permissionChanged() =>
      _lifecycle(WidgetsBinding.instance.lifecycleState);
  late final int Function() _awake;
  Future<void>? _clockSampling;
  int _lifecycleSerial = 0;
  int? _clockLifecycle;
  int? _sleepLower;
  int _sleepAdded = 0, _lastAwake = 0;
  AndroidPlatformContext? _context;
  Future<AndroidPlatformContext>? _initializing;
  Future<void>? _disposing;
  final _pending = <Future<void>>{};
  final _changes = StreamController<PlatformLifecyclePhase>.broadcast(
    sync: true,
  );
  bool _stopping = false,
      _disposed = false,
      _observing = false,
      _picking = false;
  int _serial = 0, _pickSerial = 0;
  PlatformLifecyclePhase _phase = PlatformLifecyclePhase.paused;
  String get epoch =>
      _context?.epoch ??
      (throw const AndroidPlatformFailure('NOT_INITIALIZED'));
  @override
  PlatformCapabilities get capabilities => PlatformCapabilities.android;
  @override
  PlatformLifecyclePhase get phase => _phase;
  @override
  Stream<PlatformLifecyclePhase> get changes => _changes.stream;
  void _admit() {
    if (_stopping || _disposed)
      throw const AndroidPlatformFailure('SHUTTING_DOWN');
  }

  AndroidPlatformFailure _failure(Object error) {
    if (error is AndroidPlatformFailure) return error;
    const known = {
      'INVALID_ARGUMENT',
      'PROTECTION_UNAVAILABLE',
      'STORAGE_IO',
      'RESOURCE_EXHAUSTED',
      'KEY_PICK_UNAVAILABLE',
      'BROWSER_UNAVAILABLE',
      'TIMEOUT',
      'CANCELLED',
      'STALE_OWNER',
      'SHUTTING_DOWN',
      'UNSUPPORTED_PLATFORM',
    };
    return AndroidPlatformFailure(
      error is PlatformException && known.contains(error.code)
          ? error.code
          : 'PLATFORM_UNAVAILABLE',
    );
  }

  Future<AndroidPlatformContext> initialize() {
    try {
      _admit();
    } catch (error) {
      return Future.error(error);
    }
    if (_context case final saved?) return Future.value(saved);
    return _initializing ??= _initialize().whenComplete(
      () => _initializing = null,
    );
  }

  Future<AndroidPlatformContext> _initialize() async {
    try {
      final value = await _channel.invokeMethod<Object?>('initialize', {
        'version': 1,
      });
      if (value is! Map ||
          value.length != 4 ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['platform'] != 'android' ||
          value['ownerEpoch'] is! String ||
          !isCanonicalUuid(value['ownerEpoch'] as String) ||
          value['dataRoot'] is! String) {
        throw const AndroidPlatformFailure('INVALID_PLATFORM_REPLY');
      }
      final root = value['dataRoot'] as String;
      if (root.length > 4096 ||
          !RegExp(r'^/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+$').hasMatch(root) ||
          root.split('/').any((part) => part == '.' || part == '..')) {
        throw const AndroidPlatformFailure('INVALID_PLATFORM_REPLY');
      }
      final result = AndroidPlatformContext(
        value['ownerEpoch'] as String,
        root,
      );
      // Keep validated context for native cleanup even if shutdown began in flight.
      _context = result;
      if (!_observing) {
        WidgetsBinding.instance.addObserver(this);
        _cameraPermissionGate.addListener(_permissionChanged);
        _observing = true;
      }
      _lifecycle(WidgetsBinding.instance.lifecycleState);
      _admit();
      return result;
    } catch (error) {
      throw _failure(error);
    }
  }

  Future<T> _track<T>(Future<T> Function() action) async {
    if (_pending.length >= 32)
      throw const AndroidPlatformFailure('RESOURCE_EXHAUSTED');
    final done = Completer<void>();
    _pending.add(done.future);
    try {
      return await action();
    } finally {
      _pending.remove(done.future);
      done.complete();
    }
  }

  Future<Object?> _invoke(
    String method, [
    Map<String, Object?> extra = const {},
    bool Function()? isCurrent,
  ]) => _track(() async {
    _admit();
    final serial = _serial;
    final context = await initialize();
    _admit();
    if (isCurrent != null && !isCurrent())
      throw const AndroidPlatformFailure('CANCELLED');
    try {
      final raw = await _channel.invokeMethod<Object?>(method, {
        'version': 1,
        'ownerEpoch': context.epoch,
        ...extra,
      });
      if (raw is Uint8List && raw.length > _protectedLimit)
        throw const AndroidPlatformFailure('INVALID_PLATFORM_REPLY');
      final value = raw is Uint8List ? Uint8List.fromList(raw) : raw;
      if (_disposed ||
          _stopping ||
          serial != _serial ||
          isCurrent != null && !isCurrent()) {
        if (value is Uint8List) value.fillRange(0, value.length, 0);
        throw const AndroidPlatformFailure('CANCELLED');
      }
      return value;
    } catch (error) {
      throw _failure(error);
    }
  });
  void _purpose(String purpose) {
    if (purpose.isEmpty ||
        purpose.length > 128 ||
        RegExp(r'[^\x21-\x7e]').hasMatch(purpose)) {
      throw const AndroidPlatformFailure('INVALID_ARGUMENT');
    }
  }

  Future<Uint8List> _binary(
    String method,
    Uint8List input,
    String purpose, {
    required int inputLimit,
    required int outputLimit,
  }) async {
    _admit();
    if (_pending.length >= 32)
      throw const AndroidPlatformFailure('RESOURCE_EXHAUSTED');
    _purpose(purpose);
    if (input.length > inputLimit)
      throw const AndroidPlatformFailure('INVALID_ARGUMENT');
    final owned = Uint8List.fromList(input);
    try {
      final value = await _invoke(method, {'bytes': owned, 'purpose': purpose});
      if (value is! Uint8List ||
          value.length > outputLimit ||
          method == 'secret.protect' && value.isEmpty) {
        if (value is Uint8List) value.fillRange(0, value.length, 0);
        throw const AndroidPlatformFailure('INVALID_PLATFORM_REPLY');
      }
      return value;
    } finally {
      owned.fillRange(0, owned.length, 0);
    }
  }

  @override
  Future<Uint8List> protect(Uint8List bytes, String purpose) => _binary(
    'secret.protect',
    bytes,
    purpose,
    inputLimit: _secretLimit,
    outputLimit: _protectedLimit,
  );
  @override
  Future<Uint8List> unprotect(Uint8List bytes, String purpose) => _binary(
    'secret.unprotect',
    bytes,
    purpose,
    inputLimit: _protectedLimit,
    outputLimit: _secretLimit,
  );
  @override
  Future<Uint8List?> pickPrivateKey() async {
    _admit();
    if (_picking) throw const AndroidPlatformFailure('RESOURCE_EXHAUSTED');
    _picking = true;
    final serial = _pickSerial;
    try {
      final value = await _invoke(
        'credential.pickKey',
        const {},
        () => serial == _pickSerial,
      );
      if (serial != _pickSerial) {
        if (value is Uint8List) value.fillRange(0, value.length, 0);
        throw const AndroidPlatformFailure('CANCELLED');
      }
      if (value == null) return null;
      if (value is! Uint8List || value.length > _secretLimit) {
        if (value is Uint8List) value.fillRange(0, value.length, 0);
        throw const AndroidPlatformFailure('INVALID_PLATFORM_REPLY');
      }
      return value;
    } finally {
      _picking = false;
    }
  }

  @override
  Future<void> openServicePage({
    required Uri serviceOrigin,
    required Uri page,
  }) async {
    try {
      final origin = SyncServiceOrigin(serviceOrigin.toString()).value;
      final target = page.toString();
      if (target != '$origin/devices' &&
          target != '$origin/account' &&
          target != '$origin/activate' &&
          !RegExp(
            '^${RegExp.escape(origin)}/activate\\?user_code=[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{10}\$',
          ).hasMatch(target)) {
        throw const AndroidPlatformFailure('INVALID_ARGUMENT');
      }
    } catch (_) {
      throw const AndroidPlatformFailure('INVALID_ARGUMENT');
    }
    await _invoke('browser.open', {
      'serviceOrigin': serviceOrigin.toString(),
      'page': page.toString(),
    });
  }

  @override
  Future<PlatformStorageLocation> prepareStorage() => _track(() async {
    _admit();
    final serial = _serial;
    final context = await initialize();
    if (_disposed || _stopping || serial != _serial)
      throw const AndroidPlatformFailure('CANCELLED');
    return BundledLibraryStorageLocation(dataRoot: context.dataRoot);
  });
  @override
  Future<int> availableStorageBytes() async {
    final value = await _invoke('storage.availableBytes');
    if (value is! int || value < 0 || value > 9007199254740991)
      throw const AndroidPlatformFailure('INVALID_PLATFORM_REPLY');
    return value;
  }

  @override
  Future<void> flushAtomic(String path, Uint8List bytes) async {
    if (bytes.length > _metadataLimit)
      throw const AndroidPlatformFailure('INVALID_ARGUMENT');
    final flush = path.startsWith('data/flush/'),
        publish = path.startsWith('data/publish/');
    try {
      if (flush || publish) {
        final id = path.substring(flush ? 11 : 13);
        if (!isCanonicalUuid(id) || flush && bytes.isNotEmpty)
          throw const AndroidPlatformFailure('INVALID_ARGUMENT');
        if (publish &&
            (StoreManifest.decode(bytes).storeId != id ||
                !listEquals(StoreManifest(id).encode(), bytes)))
          throw const AndroidPlatformFailure('INVALID_ARGUMENT');
      } else if (path == 'data/CURRENT.json') {
        final manifest = StoreManifest.decode(bytes);
        if (!listEquals(manifest.encode(), bytes))
          throw const AndroidPlatformFailure('INVALID_ARGUMENT');
      } else {
        throw const AndroidPlatformFailure('INVALID_ARGUMENT');
      }
    } catch (_) {
      throw const AndroidPlatformFailure('INVALID_ARGUMENT');
    }
    final owned = Uint8List.fromList(bytes);
    try {
      await _invoke('file.flushAtomic', {'path': path, 'bytes': owned});
    } finally {
      owned.fillRange(0, owned.length, 0);
    }
  }

  void _lifecycle(AppLifecycleState? state) {
    if (_cameraPermissionGate.preserveInactive(
      state,
      _phase == PlatformLifecyclePhase.resumed,
    ))
      return;
    final next = switch (state) {
      AppLifecycleState.resumed => PlatformLifecyclePhase.resumed,
      AppLifecycleState.detached => PlatformLifecyclePhase.detached,
      _ => PlatformLifecyclePhase.paused,
    };
    if (next != _phase && !_disposed) {
      _phase = next;
      _lifecycleSerial++;
      _changes.add(next);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _lifecycle(state);

  /// Root samples before constructing sync owners and before foreground resume.
  /// Add an upper bound of sleep since the previous lower-bound sample, so
  /// suspend cannot extend a retained authorization's original deadline.
  Future<void> refreshMonotonicClock() {
    final existing = _clockSampling;
    if (existing != null) {
      if (_clockLifecycle == _lifecycleSerial) return existing;
      // A new foreground must not join a pre-suspend native sample.
      return existing
          .then<void>((_) {}, onError: (Object _) {})
          .then((_) => refreshMonotonicClock());
    }
    _clockLifecycle = _lifecycleSerial;
    final result = _sampleClock();
    late final Future<void> tracked;
    tracked = result.whenComplete(() {
      if (identical(_clockSampling, tracked)) {
        _clockSampling = null;
        _clockLifecycle = null;
      }
    });
    _clockSampling = tracked;
    return tracked;
  }

  Future<void> _sampleClock() async {
    await initialize();
    _admit();
    final serial = _serial, lifecycle = _lifecycleSerial;
    _clockLifecycle = lifecycle;
    final value = await _invoke(
      'clock.sleepBounds',
      const {},
      () => lifecycle == _lifecycleSerial,
    );
    _admit();
    if (serial != _serial || lifecycle != _lifecycleSerial)
      throw const AndroidPlatformFailure('CANCELLED');
    const bound = 9007199254740991;
    if (value is! Map ||
        value.length != 2 ||
        value['lowerMicros'] is! int ||
        value['upperMicros'] is! int)
      throw const AndroidPlatformFailure('INVALID_PLATFORM_REPLY');
    final lower = value['lowerMicros'] as int,
        upper = value['upperMicros'] as int;
    if (lower < -bound || upper > bound || upper < lower)
      throw const AndroidPlatformFailure('INVALID_PLATFORM_REPLY');
    final delta = _sleepLower == null
        ? 0
        : (upper - _sleepLower!).clamp(0, bound + 1);
    if (delta > bound || _sleepAdded > bound - delta)
      throw const AndroidPlatformFailure('TIMEOUT');
    _sleepAdded += delta;
    _sleepLower = lower;
  }

  int monotonicMicros() {
    if (_disposed || _sleepLower == null)
      throw const AndroidPlatformFailure('CLOCK_UNAVAILABLE');
    final awake = _awake();
    if (awake < _lastAwake ||
        awake < 0 ||
        awake > 9007199254740991 - _sleepAdded)
      throw const AndroidPlatformFailure('TIMEOUT');
    _lastAwake = awake;
    return awake + _sleepAdded;
  }

  Future<void> _readyForControl() async {
    try {
      await _initializing;
    } catch (_) {
      /* Validated context still permits cleanup. */
    }
  }

  Future<void> _control(String method) async {
    final context = _context;
    if (context == null || _disposed) return;
    try {
      await _channel.invokeMethod<void>(method, {
        'version': 1,
        'ownerEpoch': context.epoch,
      });
    } catch (error) {
      throw _failure(error);
    }
  }

  Future<void> stopAdmission() async {
    if (_disposed) return;
    if (!_stopping) {
      _stopping = true;
      _serial++;
      _pickSerial++;
    }
    await _readyForControl();
    await _control('platform.stopAdmission');
  }

  Future<void> cancelPending() async {
    _pickSerial++;
    await _control('credential.cancelPick');
  }

  Future<void> drain() async {
    if (!_stopping) throw const AndroidPlatformFailure('INVALID_ARGUMENT');
    await _readyForControl();
    while (_pending.isNotEmpty) {
      await Future.wait(List.of(_pending));
    }
    await _control('platform.drain');
  }

  Future<void> dispose() {
    if (_disposed) return Future.value();
    return _disposing ??= _dispose().whenComplete(() => _disposing = null);
  }

  Future<void> _dispose() async {
    await stopAdmission();
    await drain();
    await _control('platform.dispose');
    _disposed = true;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _cameraPermissionGate.removeListener(_permissionChanged);
    unawaited(_changes.close());
  }
}
