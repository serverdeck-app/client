import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/sync/device_view.dart';
import 'package:serverdeck/sync/account_view.dart' show SyncAccountView;
import 'package:serverdeck/sync/sync_http.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/theme/brand_theme.dart';
import 'package:serverdeck/ui/deck_components.dart';

import '../fixtures/feature_harness.dart';
import '../fixtures/sync_lifecycle.dart';
import 'transport_test.dart' as wire;

Finder key(String id) => find.byKey(ValueKey(id));
Future<LifecycleHarness> harness(WidgetTester t) async =>
    (await t.runAsync(() async {
      final h = LifecycleHarness();
      await h.setup();
      return h;
    }))!;
Future<void> show(WidgetTester t, LifecycleHarness h) async {
  await t.pumpWidget(
    MaterialApp(
      theme: BrandTheme.dark,
      home: Scaffold(
        body: SingleChildScrollView(child: SyncDeviceView(owner: h.owner)),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, String id) async {
  final widget = t.widget(key(id));
  await t.runAsync(() async {
    if (widget is DeckButton) {
      final callback = widget.onPressed;
      expect(callback, isNotNull);
      unawaited(Future<void>.sync(callback!));
    } else if (widget is CheckboxListTile) {
      expect(widget.onChanged, isNotNull);
      widget.onChanged!(!(widget.value ?? false));
    } else {
      throw StateError('Unknown functional action');
    }
    await Future<void>.delayed(Duration.zero);
  });
  await t.pumpAndSettle();
}

Future<void> finish(WidgetTester t, LifecycleHarness h) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.runAsync(h.dispose);
}

bool enabled(WidgetTester t, String id) =>
    t.widget<DeckButton>(key(id)).onPressed != null;

void main() {
  testWidgets(
    'device list is explicit, own marker and web revoke expose no secrets',
    (t) async {
      final h = await harness(t);
      h.devices.addAll([
        {
          'id': h.local.fence.identity.deviceId,
          'name': 'Desktop',
          'platform': 'windows',
          'last_seen_at': 1794500000,
        },
        {
          'id': featureId(9001),
          'name': 'Phone',
          'platform': 'android',
          'last_seen_at': 9007199254740991,
        },
      ]);
      await show(t, h);
      expect(h.http.requests, isEmpty);
      await tap(t, 'sync-devices-refresh');
      expect(find.text('Desktop'), findsOneWidget);
      expect(find.text('Phone'), findsOneWidget);
      expect(find.text('Это устройство'), findsOneWidget);
      expect(find.textContaining('Дата недоступна'), findsOneWidget);
      final before = h.count('/v1/devices');
      await tap(t, 'sync-device-web-${featureId(9001)}');
      expect(
        h.browser.pages.single.$2.toString(),
        'https://sync.example.test/devices',
      );
      expect(h.count('/v1/devices'), before);
      expect(
        h.http.requests.where((r) => r.uri.path.endsWith('/revoke')),
        isEmpty,
      );
      for (final token in [
        wire.token(3),
        wire.token(4),
        'opaque.proof.synthetic',
      ]) {
        expect(find.textContaining(token), findsNothing);
      }
      expect(find.textContaining('замените'), findsOneWidget);
      await finish(t, h);
    },
  );

  testWidgets(
    'logout preview defaults keep; cancel preserves data; confirm requires fresh consent',
    (t) async {
      final h = await harness(t);
      final id = await t.runAsync(h.local.feature.create);
      await show(t, h);
      await tap(t, 'sync-logout');
      expect(find.text('Серверов: 1; карточек ПО: 0'), findsOneWidget);
      expect(
        t.widget<CheckboxListTile>(key('sync-clear-local')).value,
        isFalse,
      );
      expect(enabled(t, 'sync-disconnect-confirm'), isFalse);
      await tap(t, 'sync-disconnect-consent');
      expect(enabled(t, 'sync-disconnect-confirm'), isTrue);
      await tap(t, 'sync-disconnect-cancel');
      expect(h.local.feature.repository.state.syncState.enabled, isTrue);
      expect(h.http.requests, isEmpty);
      await tap(t, 'sync-logout');
      expect(enabled(t, 'sync-disconnect-confirm'), isFalse);
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-disconnect-confirm');
      expect(h.local.feature.repository.state.profiles.containsKey(id), isTrue);
      expect(h.local.feature.repository.state.syncState.enabled, isFalse);
      expect(find.textContaining('Локальный выход завершён'), findsOneWidget);
      expect(find.textContaining('Сервис подтвердил отзыв'), findsOneWidget);
      await finish(t, h);
    },
  );

  testWidgets(
    'clear requires new consent and removes local records only on confirm',
    (t) async {
      final h = await harness(t);
      await t.runAsync(h.local.feature.create);
      await show(t, h);
      await tap(t, 'sync-switch-account');
      expect(find.textContaining('импорт'), findsWidgets);
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-clear-local');
      expect(enabled(t, 'sync-disconnect-confirm'), isFalse);
      expect(h.local.feature.repository.state.profiles, isNotEmpty);
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-disconnect-confirm');
      expect(h.local.feature.repository.state.profiles, isEmpty);
      await finish(t, h);
    },
  );

  testWidgets(
    'offline logout reports local success and permits old service web reconciliation',
    (t) async {
      final h = await harness(t);
      h.handler = (r) async {
        if (r.uri.path == '/v1/logout')
          throw StateError('private-network-detail');
        return null;
      };
      await show(t, h);
      await tap(t, 'sync-logout');
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-disconnect-confirm');
      expect(find.textContaining('Сервис не подтвердил отзыв'), findsOneWidget);
      expect(find.textContaining('private-network-detail'), findsNothing);
      await tap(t, 'sync-left-service-web');
      expect(
        h.browser.pages.single.$2.toString(),
        'https://sync.example.test/devices',
      );
      expect(h.count('/v1/token/refresh'), 0);
      await finish(t, h);
    },
  );

  testWidgets(
    'proof reset presents recovery warning and explicit local choice before new login',
    (t) async {
      final h = await harness(t);
      await t.runAsync(h.local.feature.create);
      h.status = 'vault_reset';
      await show(t, h);
      await tap(t, 'sync-device-status');
      expect(h.owner.view.phase, SyncAuthPhase.vaultReset);
      expect(find.textContaining('Старый код'), findsOneWidget);
      await tap(t, 'sync-reset-reconnect');
      expect(h.count('/v1/device-authorizations'), 0);
      expect(find.textContaining('новый ключ'), findsWidgets);
      expect(enabled(t, 'sync-disconnect-confirm'), isFalse);
      await tap(t, 'sync-disconnect-cancel');
      expect(h.local.feature.repository.state.profiles, isNotEmpty);
      expect(h.local.feature.repository.state.syncState.enabled, isTrue);
      await finish(t, h);
    },
  );

  testWidgets('stale local preview fails safely and requires reread', (
    t,
  ) async {
    final h = await harness(t);
    await show(t, h);
    await tap(t, 'sync-logout');
    await t.runAsync(h.local.feature.create);
    await tap(t, 'sync-disconnect-consent');
    await tap(t, 'sync-disconnect-confirm');
    expect(find.textContaining('План устарел'), findsOneWidget);
    expect(key('sync-disconnect-confirm'), findsNothing);
    expect(h.local.feature.repository.state.syncState.enabled, isTrue);
    expect(h.http.requests, isEmpty);
    await finish(t, h);
  });

  testWidgets(
    'late list from replaced owner never appears or changes new actions',
    (t) async {
      final a = await harness(t);
      final b = await harness(t);
      final response = Completer<SyncHttpResponse>();
      a.handler = (r) async =>
          r.uri.path == '/v1/devices' ? response.future : null;
      await show(t, a);
      await tap(t, 'sync-devices-refresh');
      expect(enabled(t, 'sync-logout'), isFalse);
      await show(t, b);
      response.complete(
        wire.jsonResponse({
          'devices': [
            {
              'id': featureId(9002),
              'name': 'OLD-DEVICE',
              'platform': 'windows',
              'last_seen_at': 1,
            },
          ],
        }),
      );
      await t.pumpAndSettle();
      expect(find.text('OLD-DEVICE'), findsNothing);
      expect(enabled(t, 'sync-logout'), isTrue);
      await t.runAsync(a.dispose);
      await finish(t, b);
    },
  );
  testWidgets(
    'self revoke uses native local-first confirmation without other device request',
    (t) async {
      final h = await harness(t);
      await show(t, h);
      await tap(t, 'sync-self-revoke');
      expect(find.text('Отзыв этого устройства'), findsOneWidget);
      expect(h.http.requests, isEmpty);
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-disconnect-confirm');
      expect(h.count('/v1/logout'), 0);
      expect(
        h.count('/v1/devices/${h.local.fence.identity.deviceId}/revoke'),
        1,
      );
      expect(h.local.feature.repository.state.syncState.enabled, isFalse);
      await finish(t, h);
    },
  );

  testWidgets(
    'failed final clear shows blocked state and fresh keep retry preserves data',
    (t) async {
      final h = await harness(t);
      await t.runAsync(h.local.feature.create);
      h.local.batches.afterClose = () async {
        h.local.feature.repository.failCommit = true;
      };
      await show(t, h);
      await tap(t, 'sync-logout');
      await tap(t, 'sync-clear-local');
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-disconnect-confirm');
      expect(h.owner.view.phase, SyncAuthPhase.disconnectRequired);
      expect(find.textContaining('Завершите локальный выход'), findsOneWidget);
      expect(key('sync-disconnect-confirm'), findsNothing);
      expect(h.local.feature.repository.state.profiles, isNotEmpty);
      expect(h.count('/v1/logout'), 0);
      h.local.batches.afterClose = null;
      await tap(t, 'sync-logout');
      expect(
        t.widget<CheckboxListTile>(key('sync-clear-local')).value,
        isFalse,
      );
      expect(enabled(t, 'sync-disconnect-confirm'), isFalse);
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-disconnect-confirm');
      expect(h.local.feature.repository.state.profiles, isNotEmpty);
      expect(h.local.feature.repository.state.syncState.enabled, isFalse);
      await finish(t, h);
    },
  );

  testWidgets(
    'detached intent requires explicit discard and does not delete current profiles',
    (t) async {
      final h = await harness(t);
      await t.runAsync(() async {
        final id = await h.local.feature.create();
        await h.local.remote([h.local.stored(id)], pending: true);
        await h.lifecycle.disconnect(await h.lifecycle.preview());
      });
      await show(t, h);
      await tap(t, 'sync-detached-preview');
      expect(find.text('Старых ожидающих копий: 1'), findsOneWidget);
      expect(enabled(t, 'sync-detached-delete'), isFalse);
      await tap(t, 'sync-detached-consent');
      await tap(t, 'sync-detached-cancel');
      expect(h.local.feature.repository.state.syncRoots, isNotEmpty);
      await tap(t, 'sync-detached-preview');
      expect(enabled(t, 'sync-detached-delete'), isFalse);
      await tap(t, 'sync-detached-consent');
      await tap(t, 'sync-detached-delete');
      expect(h.local.feature.repository.state.syncRoots, isEmpty);
      expect(h.local.feature.repository.state.profiles, isNotEmpty);
      await tap(t, 'sync-cache-reclaim');
      expect(
        find.textContaining('Очистка неиспользуемого кэша завершена'),
        findsOneWidget,
      );
      await finish(t, h);
    },
  );

  testWidgets(
    'second detached group blocks keep until separate old-copy choice',
    (t) async {
      final h = await harness(t);
      await t.runAsync(() async {
        final id = await h.local.feature.create();
        await h.local.remote([h.local.stored(id)], pending: true);
        await h.lifecycle.disconnect(await h.lifecycle.preview());
        await h.login(
          account: featureId(9300),
          vault: featureId(9301),
          device: featureId(9302),
        );
        await h.local.repository.stageRoot(
          h.local.repository.capture(),
          rootId: featureId(9310),
          snapshotId: featureId(9311),
          revision: 1,
          sourceGeneration:
              h.local.feature.repository.state.syncState.syncGeneration,
          rootCiphertext: Uint8List(28),
          objects: const [],
          pending: true,
          commitId: featureId(9312),
        );
      });
      await show(t, h);
      await tap(t, 'sync-logout');
      await tap(t, 'sync-disconnect-consent');
      expect(enabled(t, 'sync-disconnect-confirm'), isFalse);
      await tap(t, 'sync-discard-previous');
      expect(
        t.widget<CheckboxListTile>(key('sync-disconnect-consent')).value,
        isFalse,
      );
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-disconnect-confirm');
      expect(h.local.feature.repository.state.syncRoots.keys, [
        featureId(9310),
      ]);
      expect(h.local.feature.repository.state.profiles, isNotEmpty);
      await finish(t, h);
    },
  );

  testWidgets(
    'late A list does not leave error or old content after same owner binds B',
    (t) async {
      final h = await harness(t);
      final response = Completer<SyncHttpResponse>();
      h.handler = (r) async =>
          r.uri.path == '/v1/devices' ? response.future : null;
      await show(t, h);
      await tap(t, 'sync-devices-refresh');
      await t.runAsync(() async {
        await h.lifecycle.disconnect(await h.lifecycle.preview());
        h.handler = null;
        await h.login(
          account: featureId(9400),
          vault: featureId(9401),
          device: featureId(9402),
        );
        response.complete(
          wire.jsonResponse({
            'devices': [
              {
                'id': featureId(9403),
                'name': 'OLD-A',
                'platform': 'android',
                'last_seen_at': 1,
              },
            ],
          }),
        );
        await featureTurns();
      });
      await t.pumpAndSettle();
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      expect(find.text('OLD-A'), findsNothing);
      expect(find.textContaining('Не удалось выполнить'), findsNothing);
      expect(find.textContaining('Локальный выход завершён'), findsNothing);
      expect(enabled(t, 'sync-logout'), isTrue);
      await finish(t, h);
    },
  );

  testWidgets(
    'closing an unconfirmed view has no side effects and next preview is unchecked',
    (t) async {
      final h = await harness(t);
      await show(t, h);
      await tap(t, 'sync-logout');
      await tap(t, 'sync-disconnect-consent');
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      expect(h.local.feature.repository.state.syncState.enabled, isTrue);
      expect(h.http.requests, isEmpty);
      await show(t, h);
      await tap(t, 'sync-logout');
      expect(enabled(t, 'sync-disconnect-confirm'), isFalse);
      await finish(t, h);
    },
  );
  testWidgets(
    'rebind shows canonical target, sends nothing before fresh consent and cancel preserves A',
    (t) async {
      final h = await harness(t);
      await t.runAsync(h.local.feature.create);
      final protected = h
          .local
          .feature
          .repository
          .state
          .syncSecrets
          .protectedAccess!
          .toList();
      await show(t, h);
      await tap(t, 'sync-change-service');
      await t.enterText(
        key('sync-next-origin'),
        'HTTPS://SYNC.EXAMPLE.TEST:443/',
      );
      await t.pump();
      expect(enabled(t, 'sync-rebind-preview'), isFalse);
      await t.enterText(key('sync-next-origin'), 'https://ПРИМЕР.РФ:8443/');
      await t.pump();
      expect(find.text('https://xn--e1afmkfd.xn--p1ai:8443'), findsOneWidget);
      expect(h.http.requests, isEmpty);
      await tap(t, 'sync-rebind-preview');
      expect(find.text('Смена сервиса синхронизации'), findsOneWidget);
      expect(enabled(t, 'sync-disconnect-confirm'), isFalse);
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-disconnect-cancel');
      expect(
        h.local.feature.repository.state.syncSecrets.protectedAccess,
        protected,
      );
      expect(
        h.local.feature.repository.state.syncState.serviceOrigin,
        h.local.fence.identity.serviceOrigin,
      );
      expect(h.http.requests, isEmpty);
      await tap(t, 'sync-rebind-preview');
      expect(enabled(t, 'sync-disconnect-confirm'), isFalse);
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-disconnect-confirm');
      final state = h.local.feature.repository.state;
      expect(state.syncState.enabled, isFalse);
      expect(
        state.syncState.serviceOrigin,
        'https://xn--e1afmkfd.xn--p1ai:8443',
      );
      expect(state.syncSecrets.protectedAccess, isNull);
      expect(state.syncSecrets.protectedRefresh, isNull);
      expect(state.syncSecrets.protectedVaultRootKey, isNull);
      expect(state.profiles.length, 1);
      expect(
        h.http.requests.every(
          (r) => r.uri.origin == h.local.fence.identity.serviceOrigin,
        ),
        isTrue,
      );
      expect(h.count('/v1/device-authorizations'), 0);
      await finish(t, h);
    },
  );

  testWidgets(
    'account login adopts new saved origin after rebind with unchecked enable consent',
    (t) async {
      final h = await harness(t);
      await t.pumpWidget(
        MaterialApp(
          theme: BrandTheme.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: SyncAccountView(
                owner: h.owner,
                platform: 'windows',
                defaultDeviceName: 'Desktop',
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await tap(t, 'sync-change-service');
      await t.enterText(
        key('sync-next-origin'),
        'HTTPS://B.EXAMPLE.TEST:8443/',
      );
      await t.pump();
      await tap(t, 'sync-rebind-preview');
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-disconnect-confirm');
      expect(
        t.widget<DeckTextField>(key('sync-service-origin')).controller!.text,
        'https://b.example.test:8443',
      );
      expect(
        t.widget<CheckboxListTile>(key('sync-enable-consent')).value,
        isFalse,
      );
      expect(enabled(t, 'sync-login'), isFalse);
      expect(
        find.widgetWithText(DeckKeyValue, 'https://b.example.test:8443'),
        findsOneWidget,
      );
      final requests = h.http.requests.length;
      await tap(t, 'sync-enable-consent');
      expect(enabled(t, 'sync-login'), isTrue);
      await t.enterText(key('sync-service-origin'), 'https://другой.рф');
      await t.pump();
      expect(
        t.widget<CheckboxListTile>(key('sync-enable-consent')).value,
        isFalse,
      );
      expect(enabled(t, 'sync-login'), isFalse);
      expect(h.http.requests.length, requests);
      await finish(t, h);
    },
  );

  testWidgets(
    'failed final rebind keeps A origin blocked until a new target preview succeeds',
    (t) async {
      final h = await harness(t);
      await t.runAsync(h.local.feature.create);
      h.local.batches.afterClose = () async {
        h.local.feature.repository.failCommit = true;
      };
      await show(t, h);
      await tap(t, 'sync-change-service');
      await t.enterText(key('sync-next-origin'), 'https://b.example.test');
      await t.pump();
      await tap(t, 'sync-rebind-preview');
      await tap(t, 'sync-clear-local');
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-disconnect-confirm');
      expect(h.owner.view.phase, SyncAuthPhase.disconnectRequired);
      expect(
        h.local.feature.repository.state.syncState.serviceOrigin,
        h.local.fence.identity.serviceOrigin,
      );
      expect(h.local.feature.repository.state.profiles, isNotEmpty);
      expect(h.http.requests, isEmpty);
      h.local.batches.afterClose = null;
      await tap(t, 'sync-rebind-preview');
      expect(
        t.widget<CheckboxListTile>(key('sync-clear-local')).value,
        isFalse,
      );
      expect(enabled(t, 'sync-disconnect-confirm'), isFalse);
      await tap(t, 'sync-disconnect-consent');
      await tap(t, 'sync-disconnect-confirm');
      expect(
        h.local.feature.repository.state.syncState.serviceOrigin,
        'https://b.example.test',
      );
      expect(h.local.feature.repository.state.profiles, isNotEmpty);
      expect(h.count('/v1/device-authorizations'), 0);
      await finish(t, h);
    },
  );
}
