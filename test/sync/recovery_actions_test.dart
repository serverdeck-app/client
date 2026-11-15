import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/sync/account_view.dart';
import 'package:serverdeck/sync/sync_http.dart';
import 'package:serverdeck/sync/sync_recovery.dart';
import 'package:serverdeck/theme/brand_theme.dart';
import 'package:serverdeck/ui/deck_components.dart';

import 'device_auth_test.dart' as auth;
import 'recovery_test.dart' as recovery;
import 'transport_test.dart' as wire;

Future<auth.Harness> signedIn(WidgetTester tester) async {
  // Fixed monotonic clock; these functional form tests do not assess expiry.
  final h = auth.Harness(FakeAsync());
  final login = h.owner.beginLogin(
    origin: wire.origin,
    platform: 'windows',
    name: 'Desktop',
  );
  await tester.pump();
  await login;
  await tester.pump(const Duration(seconds: 5));
  await tester.pump();
  return h;
}

Future<void> show(WidgetTester tester, auth.Harness h) => tester.pumpWidget(
  MaterialApp(
    theme: BrandTheme.dark,
    home: Scaffold(
      body: SingleChildScrollView(
        child: SyncRecoveryView(owner: h.owner.vault),
      ),
    ),
  ),
);
Future<void> finish(WidgetTester tester, auth.Harness h) async {
  await tester.pumpWidget(const SizedBox.shrink());
  h.owner.dispose();
  await tester.pumpAndSettle();
}

Finder get input => find.byKey(const ValueKey('recovery-code-input'));

void main() {
  testWidgets(
    'code is confined to explicit dialog; saved checkbox and checksum gate confirmation',
    (tester) async {
      final h = await signedIn(tester);
      await show(tester, h);
      expect(find.textContaining('SD1-'), findsNothing);
      await tester.tap(find.text('Проверить хранилище'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Создать код восстановления'));
      await tester.pumpAndSettle();
      final code = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .data!;
      expect(code, startsWith('SD1-'));
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      final confirm = find.widgetWithText(DeckButton, 'Подтвердить сохранение');
      expect(tester.widget<DeckButton>(confirm).onPressed, isNull);
      await tester.enterText(input, code.substring(48));
      await tester.pump();
      expect(tester.widget<DeckButton>(confirm).onPressed, isNull);
      await tester.tap(find.text('Я сохранил код восстановления'));
      await tester.pump();
      expect(tester.widget<DeckButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(h.owner.vault.view.phase, SyncVaultPhase.ready);
      expect(find.textContaining('SD1-'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('Хранилище разблокировано.'), findsOneWidget);
      expect(h.count('/v1/vault/uploads'), 0);
      await finish(tester, h);
    },
  );

  testWidgets('cancel code dialog discards draft and never stores a key', (
    tester,
  ) async {
    final h = await signedIn(tester);
    await show(tester, h);
    await tester.tap(find.text('Проверить хранилище'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Создать код восстановления'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.textContaining('SD1-'), findsNothing);
    expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
    expect(h.owner.vault.view.phase, SyncVaultPhase.unavailable);
    await finish(tester, h);
  });

  testWidgets(
    'unlock field obscures recovery input; invalid code retains saved data',
    (tester) async {
      final h = await signedIn(tester);
      recovery.serveRoot(
        h,
        recovery.encryptedRoot(h.repository.capture().identity),
      );
      await show(tester, h);
      await tester.tap(find.text('Проверить хранилище'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ввести код восстановления'));
      await tester.pumpAndSettle();
      expect(tester.widget<DeckTextField>(input).secret, isTrue);
      await tester.enterText(input, 'synthetic invalid recovery sentinel');
      await tester.pump();
      await tester.tap(find.text('Разблокировать'));
      await tester.pumpAndSettle();
      expect(
        find.text('Код не подходит или данные хранилища повреждены.'),
        findsWidgets,
      );
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      await tester.enterText(
        input,
        SyncRecoveryCodec.encode(recovery.recoveryKey()),
      );
      await tester.pump();
      await tester.tap(find.text('Разблокировать'));
      await tester.pumpAndSettle();
      expect(h.owner.vault.view.phase, SyncVaultPhase.ready);
      expect(find.byKey(const ValueKey('recovery-code-input')), findsNothing);
      expect(h.count('/v1/vault/uploads'), 0);
      await finish(tester, h);
    },
  );

  testWidgets(
    'closing section during a pending head read cancels initialization',
    (tester) async {
      final h = await signedIn(tester);
      final pending = Completer<SyncHttpResponse>();
      h.handler = (request) async =>
          request.uri.path == '/v1/vault/head' ? pending.future : null;
      await show(tester, h);
      await tester.tap(find.text('Проверить хранилище'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(h.owner.vault.view.phase, SyncVaultPhase.unavailable);
      pending.complete(
        wire.jsonResponse({
          'vault_id': wire.id(3),
          'revision': 0,
          'manifest': null,
        }),
      );
      await tester.pumpAndSettle();
      expect(h.owner.vault.view.phase, SyncVaultPhase.unavailable);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      h.owner.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'owner replacement retires old secret dialog without affecting new owner',
    (tester) async {
      final first = await signedIn(tester), second = await signedIn(tester);
      await show(tester, first);
      await tester.tap(find.text('Проверить хранилище'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Создать код восстановления'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      await show(tester, second);
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNothing);
      expect(first.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      expect(second.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      first.owner.dispose();
      await finish(tester, second);
    },
  );
}
