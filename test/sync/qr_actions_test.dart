import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:serverdeck/sync/account_view.dart';
import 'package:serverdeck/sync/sync_key_transfer.dart';
import 'package:serverdeck/sync/sync_recovery.dart';
import 'package:serverdeck/theme/brand_theme.dart';

import '../fixtures/qr_camera.dart';
import 'device_auth_test.dart' as auth;
import 'recovery_actions_test.dart' as actions;
import 'recovery_test.dart' as recovery;

Future<auth.Harness> prepare(
  WidgetTester tester, {
  bool unlocked = false,
  String platform = 'windows',
  FakeQrCamera? camera,
}) async {
  final h = await actions.signedIn(tester);
  recovery.serveRoot(
    h,
    recovery.encryptedRoot(h.repository.capture().identity),
  );
  final operation = unlocked
      ? h.owner.vault.unlock(SyncRecoveryCodec.encode(recovery.recoveryKey()))
      : h.owner.vault.inspect();
  await tester.pumpAndSettle();
  await operation;
  await tester.pumpWidget(
    MaterialApp(
      theme: BrandTheme.dark,
      home: Scaffold(
        body: SingleChildScrollView(
          child: SyncRecoveryView(
            owner: h.owner.vault,
            platform: platform,
            createCameraDriver: camera == null ? null : () => camera,
          ),
        ),
      ),
    ),
  );
  return h;
}

String qr(auth.Harness h) {
  final transfer = SyncKeyTransfer.fromKey(
    h.repository.capture().identity,
    recovery.recoveryKey(),
  );
  try {
    return transfer.payload;
  } finally {
    transfer.dispose();
  }
}

void main() {
  for (final resumeBeforeReply in [false, true]) {
    testWidgets(
      'Windows late QR preparation is retired after focus loss; resume=$resumeBeforeReply',
      (tester) async {
        final h = await prepare(tester, unlocked: true);
        final reply = Completer<void>(), original = h.handler!;
        h.handler = (request) async {
          await reply.future;
          return original(request);
        };
        await tester.tap(find.text('Показать QR для Android'));
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        if (resumeBeforeReply)
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        reply.complete();
        await tester.pumpAndSettle();
        expect(find.byType(QrImageView), findsNothing);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        h.handler = original;
        await tester.tap(find.text('Показать QR для Android'));
        await tester.pumpAndSettle();
        expect(find.byType(QrImageView), findsOneWidget);
        await tester.tap(find.text('Скрыть QR'));
        await tester.pumpAndSettle();
        await actions.finish(tester, h);
      },
    );
  }
  setUp(
    () => TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  testWidgets('Windows explicit QR hides after60s without locking the vault', (
    tester,
  ) async {
    final h = await prepare(tester, unlocked: true);
    expect(find.byType(QrImageView), findsNothing);
    await tester.tap(find.text('Показать QR для Android'));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('SDQR1:'), findsNothing);
    expect(find.textContaining('сохранённая копия'), findsOneWidget);
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
    expect(h.owner.vault.view.phase, SyncVaultPhase.ready);
    await actions.finish(tester, h);
  });
  testWidgets('Windows hides secret QR immediately on focus loss', (
    tester,
  ) async {
    final h = await prepare(tester, unlocked: true);
    await tester.tap(find.text('Показать QR для Android'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
    await actions.finish(tester, h);
  });
  testWidgets(
    'Android decodes privately, stops camera and requires explicit unlock',
    (tester) async {
      final camera = FakeQrCamera();
      final h = await prepare(tester, platform: 'android', camera: camera);
      expect(find.text('Показать QR для Android'), findsNothing);
      await tester.tap(find.text('Сканировать QR'));
      await tester.pumpAndSettle();
      final payload = qr(h);
      camera.send(payload);
      camera.send(payload);
      await tester.pumpAndSettle();
      expect(camera.disposals, 1);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      expect(find.textContaining('QR проверен'), findsOneWidget);
      expect(find.textContaining('SDQR1:'), findsNothing);
      await tester.tap(find.text('Разблокировать'));
      await tester.pumpAndSettle();
      expect(h.owner.vault.view.phase, SyncVaultPhase.ready);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNotNull);
      expect(h.count('/v1/vault/uploads'), 0);
      await actions.finish(tester, h);
    },
  );
  testWidgets('invalid input and cancellation never persist a scanned key', (
    tester,
  ) async {
    final camera = FakeQrCamera();
    final h = await prepare(tester, platform: 'android', camera: camera);
    await tester.tap(find.text('Сканировать QR'));
    await tester.pumpAndSettle();
    camera.send('synthetic secret invalid');
    await tester.pumpAndSettle();
    expect(find.textContaining('QR не подходит'), findsOneWidget);
    expect(find.textContaining('synthetic secret'), findsNothing);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
    await actions.finish(tester, h);
  });
  testWidgets(
    'scan cancellation and manual fallback keep manual recovery available',
    (tester) async {
      final camera = FakeQrCamera()..failStart = true;
      final h = await prepare(tester, platform: 'android', camera: camera);
      await tester.tap(find.text('Сканировать QR'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ввести вручную'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recovery-code-input')), findsOneWidget);
      expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
      await actions.finish(tester, h);
    },
  );
  testWidgets('candidate is retired by pause and cannot unlock afterward', (
    tester,
  ) async {
    final camera = FakeQrCamera();
    final h = await prepare(tester, platform: 'android', camera: camera);
    await tester.tap(find.text('Сканировать QR'));
    await tester.pumpAndSettle();
    camera.send(qr(h));
    await tester.pumpAndSettle();
    h.owner.pause();
    await tester.pumpAndSettle();
    expect(find.text('Разблокировать'), findsNothing);
    expect(h.domain.state.syncSecrets.protectedVaultRootKey, isNull);
    await actions.finish(tester, h);
  });
  testWidgets('scan dialog has a total120s lifetime', (tester) async {
    final camera = FakeQrCamera();
    final h = await prepare(tester, platform: 'android', camera: camera);
    await tester.tap(find.text('Сканировать QR'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 120));
    await tester.pumpAndSettle();
    expect(find.text('Сканировать ключ хранилища'), findsNothing);
    expect(camera.disposals, 1);
    await actions.finish(tester, h);
  });
}
