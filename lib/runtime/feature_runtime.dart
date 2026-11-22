import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../connections/connection_owner.dart';
import '../connections/owned_dial.dart';
import '../journals/journal_owner.dart';
import '../connections/host_signature.dart';
import '../connections/private_signer.dart';
import '../domain/actor.dart';
import '../domain/models.dart';
import '../console/console_owner.dart';
import '../console/console_settings.dart';
import '../domain/app_operations.dart';
import '../domain/canonical_state.dart';
import '../domain/mutation_receipts.dart';
import '../domain/owned_app_operations.dart';
import '../domain/receipt_book.dart';
import '../mcp/grant_owner.dart';
import '../mcp/pipe_adapter.dart';
import '../mcp/router.dart';
import '../mcp/tool_schemas.dart';
import '../profiles/credential_input.dart';
import '../profiles/key_parse_worker.dart';
import '../profiles/profile_owner.dart';
import '../storage/domain_repository.dart';
import '../software/software_owner.dart';
import '../trust/trust_owner.dart';
import '../monitoring/monitoring_owner.dart';
import '../updates/update_owner.dart';
import 'capability.dart';
import 'native_platform.dart';
import 'local_diagnostics.dart';
import 'platform_ports.dart';
import 'owned_work.dart';
import '../sync/sync_runtime.dart';
import '../sync/sync_http.dart';
import '../sync/sync_transport.dart';

final class _Protector implements SecretProtector {
  const _Protector(this.platform);
  final PlatformSecretPort platform;
  @override
  Future<Uint8List> protect(Uint8List bytes, String purpose) =>
      platform.protect(bytes, purpose);
}

/// Complete owner graph, built before RuntimeCoordinator admits any operations.
final class FeatureRuntime implements RuntimeCapability {
  FeatureRuntime({
    required NativePlatform platform,
    required this.repository,
    required this.signer,
    required this.isRunning,
  }) : _windows = platform,
       secrets = platform,
       keyPicker = platform,
       _ownerEpoch = platform.epoch,
       _dataRoot = platform.context.dataRoot,
       _beginDial = null,
       _createTransport = null,
       _connectionClock = null,
       _connectionSchedule = null,
       capabilities = PlatformCapabilities.windows {
    _buildShared();
    _buildDesktop();
  }

  FeatureRuntime.android({
    required this.secrets,
    required this.keyPicker,
    required String ownerEpoch,
    required String dataRoot,
    required this.repository,
    required this.signer,
    required this.isRunning,
    BeginSshDial? beginDial,
    CreateSshConnection? createTransport,
    Duration Function()? connectionClock,
    ScheduleOwnedDeadline? connectionSchedule,
  }) : _windows = null,
       _ownerEpoch = ownerEpoch,
       _dataRoot = dataRoot,
       _beginDial = beginDial,
       _createTransport = createTransport,
       _connectionClock = connectionClock,
       _connectionSchedule = connectionSchedule,
       capabilities = PlatformCapabilities.android {
    _buildShared();
  }

  void _buildShared() {
    actors = ActorAuthority(_ownerEpoch);
    parser = CancellableKeyParser();
    verifier = HostSignatureVerifier();
    privateSigner = PrivateSigner();
    connections = ConnectionOwner(
      actors: actors,
      repository: repository,
      getGate: () => gate,
      getState: () => state,
      getTrust: () => trust,
      unprotect: secrets.unprotect,
      verifier: verifier,
      signer: privateSigner,
      newId: newId,
      utcNow: utcNow,
      beginDial: _beginDial,
      createTransport: _createTransport,
      monotonicNow: _connectionClock,
      schedule: _connectionSchedule,
    );
    state = CanonicalOperationState(
      actors: actors,
      repository: repository,
      isRunning: () => !_stopped && isRunning(),
      grants: _GrantPolicy(() => grantOwner),
      connections: connections,
    );
    final diagnostics = LocalDiagnostics(_dataRoot);
    gate = DomainCommandGate(
      actors: actors,
      state: state,
      onFailure: (error, stack) => diagnostics.record('command', error, stack),
    );
    final receipts = ReceiptBook(signer, utcNow);
    software = SoftwareOwner(
      gate: gate,
      repository: repository,
      receipts: receipts,
      newId: newId,
      utcNow: utcNow,
    );
    trust = TrustOwner(
      repository: repository,
      getGate: () => gate,
      connections: connections,
      receipts: receipts,
      newId: newId,
      utcNow: utcNow,
    );
    profiles = ProfileOwner(
      onFailure: (error, stack) => diagnostics.record('profile', error, stack),
      gate: gate,
      repository: repository,
      receipts: receipts,
      credentials: CredentialPreparer(_Protector(secrets), parser),
      connections: connections,
      newId: newId,
      utcNow: utcNow,
    );
    operations = OwnedAppOperations(profiles, connections, trust);
    _capabilities = [
      software,
      profiles,
      trust,
      connections,
      parser,
      verifier,
      privateSigner,
    ];
  }

  void _buildDesktop() {
    final platform = this.platform;
    pipe = McpPipeAdapter(
      port: NativeMcpPipePort(platform),
      ownerEpoch: platform.epoch,
      getGrants: () => grants,
      getRouter: () => router,
      utcNow: utcNow,
      onUnavailable: () =>
          mcpError = 'Канал MCP недоступен. Повторите его запуск в настройках.',
    );
    grants = GrantOwner(
      repository: repository,
      actors: actors,
      getGate: () => gate,
      connections: connections,
      transport: pipe,
      protect: platform.protect,
      unprotect: platform.unprotect,
      newId: newId,
      utcNow: utcNow,
      userSid: platform.context.userSid,
      logonSid: platform.context.logonSid,
      exePath: platform.context.exePath,
      onClientInvalidated: (clientId) => consoles.invalidateClient(clientId),
    );
    consoleSettings = ConsoleSettingsOwner(
      actors: actors,
      gate: gate,
      repository: repository,
      onChanged: () => consoles.configurationChanged(),
    );
    consoles = ConsoleOwner(
      actors: actors,
      gate: gate,
      state: state,
      repository: repository,
      connections: connections,
      configuration: () => consoleSettings.snapshot,
      newId: newId,
    );
    monitoring = MonitoringOwner(
      historyStore: repository,
      operations: operations,
      actor: actors.ui,
      connections: connections,
      isSyncAutoBlocked: connections.isSyncAutoBlocked,
      utcNow: utcNow,
    );
    journals = JournalsOwner(
      repository: repository,
      actor: actors.ui,
      connections: connections,
      newId: newId,
      utcNow: utcNow,
    );
    updates = UpdateOwner(
      port: NativeUpdatePort(platform),
      currentVersion: platform.context.release,
    );
    _capabilities.insertAll(1, [
      consoles,
      consoleSettings,
      updates,
      journals,
      monitoring,
      pipe,
      grants,
    ]);
  }

  final NativePlatform? _windows;
  NativePlatform get platform =>
      _windows ?? (throw UnsupportedError('Desktop platform unavailable'));
  final PlatformSecretPort secrets;
  final PlatformKeyPickerPort keyPicker;
  final PlatformCapabilities capabilities;
  final String _ownerEpoch, _dataRoot;
  final BeginSshDial? _beginDial;
  final CreateSshConnection? _createTransport;
  final Duration Function()? _connectionClock;
  final ScheduleOwnedDeadline? _connectionSchedule;
  GrantOwner? get grantOwner => capabilities.supportsMcp ? grants : null;
  MonitoringOwner? get monitoringOwner =>
      capabilities.supportsMonitoring ? monitoring : null;
  JournalsOwner? get journalsOwner =>
      capabilities.supportsJournals ? journals : null;
  ConsoleOwner? get consoleOwner =>
      capabilities.supportsConsole ? consoles : null;
  ConsoleSettingsOwner? get terminalSettings =>
      capabilities.supportsConsole ? consoleSettings : null;
  UpdateOwner? get updateOwner => capabilities.supportsUpdates ? updates : null;
  final DomainRepository repository;
  SyncRuntime? sync;
  void configureSync({
    required PlatformBrowserPort browser,
    required Future<int> Function() availableStorageBytes,
    required int Function() monotonicMicros,
    PlatformLifecyclePort? lifecycle,
    Future<void> Function()? refreshClock,
    SyncHttpPort? http,
  }) {
    if (_stopped || _registrationClosed || sync != null)
      throw StateError('Sync registration is closed');
    final value = sync = SyncRuntime(
      domain: repository,
      gate: gate,
      actor: actors.owner,
      connections: connections,
      secrets: secrets,
      inspector: parser,
      browser: browser,
      availableStorageBytes: availableStorageBytes,
      newId: newId,
      utcNow: utcNow,
      monotonicMicros: monotonicMicros,
      lifecycle: lifecycle,
      refreshClock: refreshClock,
      isRunning: () => !_stopped && isRunning(),
      transport: (origin) =>
          SyncTransport(origin: origin, http: http ?? DartSyncHttpPort()),
    );
    _capabilities.insert(0, value);
  }

  final ReceiptSigner signer;
  final bool Function() isRunning;
  late final ActorAuthority actors;
  late final CanonicalOperationState state;
  late final DomainCommandGate gate;
  late final SoftwareOwner software;
  late final CancellableKeyParser parser;
  late final HostSignatureVerifier verifier;
  late final PrivateSigner privateSigner;
  late final ConnectionOwner connections;
  late final ProfileOwner profiles;
  late final TrustOwner trust;
  late final GrantOwner grants;
  late final McpPipeAdapter pipe;
  late final OwnedAppOperations operations;
  late final ConsoleOwner consoles;
  late final ConsoleSettingsOwner consoleSettings;
  late final MonitoringOwner monitoring;
  late final JournalsOwner journals;
  late final UpdateOwner updates;
  late McpRouter router;
  late final List<RuntimeCapability> _capabilities;
  bool _stopped = false, _initialized = false, _registrationClosed = false;
  String? mcpError;
  @override
  String get id => 'feature-003';
  static int utcNow() => DateTime.now().toUtc().millisecondsSinceEpoch;
  static String newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final text = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${text.substring(0, 8)}-${text.substring(8, 12)}-${text.substring(12, 16)}-${text.substring(16, 20)}-${text.substring(20)}';
  }

  Future<void> initialize() async {
    if (_initialized || _stopped) return;
    _registrationClosed = true;
    await sync?.initialize();
    if (_stopped) return;
    if (!capabilities.supportsMcp) {
      _initialized = true;
      sync?.activate();
      return;
    }
    await journals.start();
    try {
      router = McpRouter(
        software: software,
        operations: operations,
        consoles: consoles,
        grants: grants,
        schemas: await ToolSchemas.load(),
        release: platform.context.release,
      );
      if (_stopped) return;
      await pipe.initialize();
      if (_stopped) return;
      await grants.initialize();
      if (_stopped) return;
      await pipe.setEnabled(grants.enabled);
      mcpError = null;
    } catch (_) {
      mcpError = 'MCP недоступен. Профили и SSH продолжают работать.';
      grants.transportReady(false);
      try {
        await pipe.setEnabled(false);
      } catch (_) {}
    }
    _initialized = true;
    sync?.activate();
  }

  Future<void> retryMcp() async {
    if (_stopped) return;
    if (!capabilities.supportsMcp) throw UnsupportedError('MCP unavailable');
    try {
      await pipe.setEnabled(false);
    } catch (_) {
      mcpError = 'Не удалось закрыть прежние каналы MCP. Повторите закрытие.';
      return;
    }
    _initialized = false;
    await initialize();
  }

  Future<void> _each(Future<void> Function(RuntimeCapability) action) async {
    Object? failure;
    StackTrace? trace;
    await Future.wait(
      _capabilities.map((capability) async {
        try {
          await action(capability);
        } catch (error, stack) {
          failure ??= error;
          trace ??= stack;
        }
      }),
    );
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }

  @override
  Future<void> stopAdmission() async {
    _stopped = true;
    gate.stopAdmission();
    await _each((c) => c.stopAdmission());
  }

  @override
  Future<void> cancelPending() => _each((c) => c.cancelPending());
  @override
  Future<void> closeSessions() => _each((c) => c.closeSessions());
  @override
  Future<void> drain() async {
    await _each((c) => c.drain());
    await gate.drain();
  }

  @override
  Future<void> dispose() async {
    await stopAdmission();
    await cancelPending();
    await closeSessions();
    await drain();
    await _each((c) => c.dispose());
    signer.dispose();
    repository.disposeNotifications();
  }
}

/// Root-owned delegate: Android has no grant owner and denies every MCP context.
final class _GrantPolicy implements CanonicalGrantAuthorization {
  const _GrantPolicy(this.owner);
  final CanonicalGrantAuthorization? Function() owner;
  @override
  Future<void> authorize(McpActor actor, AuthorizationPoint point) async {
    final current = owner();
    if (current == null) throw const OperationFailure(FailureCode.authRequired);
    await current.authorize(actor, point);
  }

  @override
  bool isAuthorizedNow(McpActor actor) =>
      owner()?.isAuthorizedNow(actor) ?? false;
}
