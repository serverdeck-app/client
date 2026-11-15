import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/app.dart';
import 'package:serverdeck/domain/actor.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/domain/app_operations.dart';
import 'package:serverdeck/domain/mutation_receipts.dart';
import 'package:serverdeck/runtime/feature_runtime.dart';
import 'package:serverdeck/runtime/platform_ports.dart';
import 'package:serverdeck/runtime/runtime_coordinator.dart';
import 'package:serverdeck/profiles/profile_controller.dart';
import 'package:serverdeck/profiles/profile_view.dart';
import 'package:serverdeck/theme/brand_theme.dart';
import 'package:serverdeck/ui/deck_components.dart';

import '../fixtures/domain_repository.dart';
import 'fakes.dart';
import '../profiles/profile_list_actions_test.dart' as profiles;
import '../fixtures/sync_lifecycle.dart' show LifecycleBrowser;
import '../sync/transport_test.dart' as wire;

const _epoch = '00000000-0000-4000-8000-000000000001';

class _MobilePlatform extends FakePlatform {
  int restores = 0;
  @override
  Future<bool> restore() async {
    restores++;
    throw UnsupportedError('No desktop window');
  }
}

class _Secrets implements PlatformSecretPort, PlatformKeyPickerPort {
  int calls = 0;
  @override
  Future<Uint8List> protect(Uint8List bytes, String purpose) async {
    calls++;
    return Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> unprotect(Uint8List bytes, String purpose) async {
    calls++;
    return Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> pickPrivateKey() async {
    calls++;
    return null;
  }
}

FeatureRuntime _features(
  MemoryDomainRepository repository,
  _Secrets secrets, {
  bool Function()? isRunning,
}) => FeatureRuntime.android(
  secrets: secrets,
  keyPicker: secrets,
  ownerEpoch: _epoch,
  dataRoot: 'synthetic-private-root',
  repository: repository,
  signer: ReceiptSigner(Uint8List.fromList(List.filled(32, 7))),
  isRunning: isRunning ?? () => true,
);

void main() {
  test(
    'sync registration closes before the first initialize continuation',
    () async {
      final f = _features(MemoryDomainRepository(), _Secrets());
      addTearDown(f.dispose);
      final initializing = f.initialize();
      expect(
        () => f.configureSync(
          browser: LifecycleBrowser(),
          availableStorageBytes: () async => 100 * 1024 * 1024 * 1024,
          monotonicMicros: () => 0,
        ),
        throwsStateError,
      );
      expect(f.sync, isNull);
      await initializing;
    },
  );
  test('root installs one sync pipeline on actual mobile feature graph before initialization', () async {
    final repository = MemoryDomainRepository(), secrets = _Secrets();
    final f = _features(repository, secrets);
    addTearDown(f.dispose);
    final browser = LifecycleBrowser();
    final http = wire.FakeHttp(
      (_, _) async => throw StateError('no startup HTTP'),
    );
    void configure() => f.configureSync(
      browser: browser,
      availableStorageBytes: () async => 100 * 1024 * 1024 * 1024,
      monotonicMicros: () => 0,
      http: http,
    );
    configure();
    expect(identical(f.sync!.repository.domain, repository), isTrue);
    expect(identical(f.sync!.apply.connections, f.connections), isTrue);
    expect(identical(f.sync!.apply.gate, f.gate), isTrue);
    expect(configure, throwsStateError);
    await f.initialize();
    expect(http.requests, isEmpty);
    expect(configure, throwsStateError);
  });
  testWidgets(
    'mobile cleanup failure has usable retry without desktop activation',
    (tester) async {
      final platform = _MobilePlatform()..tray = false;
      final store = FakeStore()..failClose = true;
      final runtime = RuntimeCoordinator(
        platform: platform,
        store: store,
        epoch: 'owner',
        capabilities: PlatformCapabilities.android,
      );
      addTearDown(runtime.dispose);
      await runtime.start();
      await tester.pumpWidget(
        ServerDeckApp(
          runtime: runtime,
          store: store,
          capabilities: PlatformCapabilities.android,
        ),
      );
      await runtime.requestExit();
      await tester.pump();
      expect(runtime.state, RuntimeState.shutdownBlocked);
      expect(platform.restores, 0);
      expect(find.textContaining('трее'), findsNothing);
      expect(find.text('Повторить завершение'), findsOneWidget);
      store.failClose = false;
      await tester.tap(find.text('Повторить завершение'));
      await tester.pumpAndSettle();
      expect(runtime.state, RuntimeState.terminated);
      expect(store.closes, 2);
      expect(platform.restores, 0);
    },
  );
  testWidgets('mobile profile sections expose software and settings only', (
    tester,
  ) async {
    final operations = profiles.ListOperations();
    final controller = ProfileController(
      operations: operations,
      actor: ActorAuthority(profiles.epoch).ui,
      newId: () => profiles.profileId,
      poll: false,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: BrandTheme.dark,
        home: Scaffold(
          body: ProfileViewPanel(
            controller: controller,
            pickKey: () async => null,
            capabilities: PlatformCapabilities.android,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fixture server'));
    await tester.pumpAndSettle();
    expect(tester.widget<DeckTabs>(find.byType(DeckTabs)).labels, [
      'ПО',
      'Настройки',
    ]);
    expect(find.text('Настройки'), findsOneWidget);
    for (final label in ['Журналы', 'Задания', 'Мониторинг', 'Консоль']) {
      expect(find.text(label), findsNothing);
    }
    expect(operations.connects, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test(
    'mobile shared owners use one canonical repository with no desktop owners',
    () async {
      final repository = MemoryDomainRepository(), secrets = _Secrets();
      final f = _features(repository, secrets);
      addTearDown(f.dispose);
      await f.initialize();
      expect(identical(f.connections.repository, repository), isTrue);
      expect(identical(f.profiles.repository, repository), isTrue);
      expect(identical(f.software.repository, repository), isTrue);
      expect(identical(f.trust.repository, repository), isTrue);
      expect(f.capabilities, PlatformCapabilities.android);
      expect([
        f.grantOwner,
        f.monitoringOwner,
        f.journalsOwner,
        f.consoleOwner,
        f.terminalSettings,
        f.updateOwner,
      ], everyElement(isNull));
      expect(secrets.calls, 0);
      await f.state.authorize(f.actors.ui, AuthorizationPoint.admission);
      expect(f.state.isAuthorizedNow(f.actors.ui), isTrue);
    },
  );
  test('mobile canonical policy denies own and foreign MCP contexts', () async {
    final f = _features(MemoryDomainRepository(), _Secrets());
    addTearDown(f.dispose);
    for (final authority in [
      f.actors,
      ActorAuthority('00000000-0000-4000-8000-000000000002'),
    ]) {
      final actor = authority.mcp(
        clientId: '00000000-0000-4000-8000-000000000003',
        grantVersion: 1,
      );
      await expectLater(
        f.state.authorize(actor, AuthorizationPoint.admission),
        throwsA(isA<OperationFailure>()),
      );
    }
    expect(
      f.state.isAuthorizedNow(
        f.actors.mcp(
          clientId: '00000000-0000-4000-8000-000000000003',
          grantVersion: 1,
        ),
      ),
      isFalse,
    );
  });
  test('mobile stop closes canonical command admission', () async {
    final f = _features(MemoryDomainRepository(), _Secrets());
    addTearDown(f.dispose);
    await f.stopAdmission();
    await expectLater(
      f.state.authorize(f.actors.ui, AuthorizationPoint.admission),
      throwsA(
        isA<OperationFailure>().having(
          (e) => e.code,
          'code',
          FailureCode.shuttingDown,
        ),
      ),
    );
  });
  testWidgets(
    'mobile startup never exposes tray recovery or desktop settings',
    (tester) async {
      final platform = FakePlatform()..tray = false;
      final store = FakeStore();
      final runtime = RuntimeCoordinator(
        platform: platform,
        store: store,
        epoch: 'owner',
      );
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        ServerDeckApp(
          runtime: runtime,
          store: store,
          capabilities: PlatformCapabilities.android,
        ),
      );
      expect(find.text('Открываем данные'), findsOneWidget);
      expect(find.textContaining('трея'), findsNothing);
      expect(find.textContaining('создание значка'), findsNothing);
      expect(find.text('Обновления'), findsNothing);
      await runtime.start();
      await tester.pump();
      expect(find.textContaining('трея'), findsNothing);
    },
  );
}
