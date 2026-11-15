import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/account_view.dart';
import 'package:serverdeck/sync/sync_cycle.dart';
import 'package:serverdeck/sync/sync_merge.dart';
import 'package:serverdeck/theme/brand_theme.dart';
import 'package:serverdeck/ui/deck_components.dart';

import '../fixtures/sync_ui.dart';

Finder key(String value) => find.byKey(ValueKey(value));
Future<void> show(WidgetTester tester, CycleActionsFake owner) =>
    tester.pumpWidget(
      MaterialApp(
        theme: BrandTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(child: SyncStatusView(owner: owner)),
        ),
      ),
    );
Future<void> tap(WidgetTester tester, Finder finder) async {
  final controls = find.descendant(
    of: finder,
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  );
  final target = controls.evaluate().isEmpty ? finder : controls.first;
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, SyncMergeChoice choice) async {
  tester
      .widget<DropdownButtonFormField<SyncMergeChoice>>(
        find.byType(DropdownButtonFormField<SyncMergeChoice>),
      )
      .onChanged!(choice);
  await tester.pumpAndSettle();
}

Future<void> finish(WidgetTester tester, CycleActionsFake owner) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await owner.dispose();
}

void main() {
  testWidgets(
    'offline projection shows pending size count last success and safe retry reason',
    (tester) async {
      final owner = CycleActionsFake(
        SyncCycleView(
          SyncCyclePhase.offlinePending,
          pendingChanges: 3,
          pendingBytes: 2048,
          lastSuccessUtc: DateTime.utc(2026, 11, 12, 10).millisecondsSinceEpoch,
          retryAfterSeconds: 15,
          errorCode: 'NETWORK_ERROR',
        ),
      );
      await show(tester, owner);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('2.0 КиБ'), findsOneWidget);
      expect(find.textContaining('12.11.2026'), findsOneWidget);
      expect(find.textContaining('15 с.'), findsOneWidget);
      expect(
        find.textContaining('ожидающие изменения сохранены'),
        findsOneWidget,
      );
      await tap(tester, key('sync-retry'));
      expect(owner.retries, 1);
      await finish(tester, owner);
    },
  );

  testWidgets(
    'first composition displays safe counts and requires checkbox before automatic choice',
    (tester) async {
      final preview = await uiPreview();
      final owner = CycleActionsFake(
        SyncCycleView(SyncCyclePhase.consent, preview: preview),
      );
      await show(tester, owner);
      expect(find.text('На этом устройстве'), findsOneWidget);
      expect(find.text('В сервисе'), findsOneWidget);
      expect(find.textContaining('private-local-name'), findsNothing);
      expect(find.textContaining('private-remote-name'), findsNothing);
      expect(find.textContaining('credential-private-sentinel'), findsNothing);
      expect(
        tester.widget<DeckButton>(key('sync-merge-confirm')).onPressed,
        isNull,
      );
      await tap(tester, key('sync-merge-consent'));
      await tap(tester, key('sync-merge-confirm'));
      expect(owner.confirmations, [(preview, SyncMergeChoice.automatic)]);
      expect(
        find.text('Данные подтверждены устройством и сервисом.'),
        findsOneWidget,
      );
      await finish(tester, owner);
    },
  );

  testWidgets(
    'conflict requires whole-set selection, resets consent on choice and warns about replacement',
    (tester) async {
      final preview = await uiPreview(conflicts: 1);
      final owner = CycleActionsFake(
        SyncCycleView(SyncCyclePhase.conflict, preview: preview),
      );
      await show(tester, owner);
      expect(
        tester.widget<CheckboxListTile>(key('sync-merge-consent')).onChanged,
        isNull,
      );
      expect(
        tester.widget<DeckButton>(key('sync-merge-confirm')).onPressed,
        isNull,
      );
      expect(find.textContaining('Разные версии одной записи'), findsOneWidget);
      await choose(tester, SyncMergeChoice.local);
      expect(
        find.textContaining('Набор сервиса будет заменён локальным целиком'),
        findsOneWidget,
      );
      await tap(tester, key('sync-merge-consent'));
      await choose(tester, SyncMergeChoice.server);
      expect(
        tester.widget<CheckboxListTile>(key('sync-merge-consent')).value,
        isFalse,
      );
      expect(
        tester.widget<DeckButton>(key('sync-merge-confirm')).onPressed,
        isNull,
      );
      expect(
        find.textContaining('Локальный набор будет заменён набором сервиса'),
        findsOneWidget,
      );
      await tap(tester, key('sync-merge-consent'));
      await tap(tester, key('sync-merge-confirm'));
      expect(owner.confirmations, [(preview, SyncMergeChoice.server)]);
      await finish(tester, owner);
    },
  );

  testWidgets(
    'new preview resets checkbox and choice; old acceptance never authorizes it',
    (tester) async {
      final first = await uiPreview(), next = await uiPreview(conflicts: 1);
      final owner = CycleActionsFake(
        SyncCycleView(SyncCyclePhase.consent, preview: first),
      );
      await show(tester, owner);
      await tap(tester, key('sync-merge-consent'));
      owner.emit(SyncCycleView(SyncCyclePhase.conflict, preview: next));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(key('sync-merge-consent')).value,
        isFalse,
      );
      expect(
        tester.widget<CheckboxListTile>(key('sync-merge-consent')).onChanged,
        isNull,
      );
      expect(
        tester.widget<DeckButton>(key('sync-merge-confirm')).onPressed,
        isNull,
      );
      expect(owner.confirmations, isEmpty);
      await finish(tester, owner);
    },
  );

  testWidgets('stale confirm requires refresh and does not expose exceptions', (
    tester,
  ) async {
    final preview = await uiPreview();
    final owner = CycleActionsFake(
      SyncCycleView(SyncCyclePhase.consent, preview: preview),
    );
    owner.onConfirm = () async =>
        throw const OperationFailure(FailureCode.conflict);
    await show(tester, owner);
    await tap(tester, key('sync-merge-consent'));
    await tap(tester, key('sync-merge-confirm'));
    expect(find.textContaining('План устарел'), findsOneWidget);
    expect(
      tester.widget<DeckButton>(key('sync-merge-confirm')).onPressed,
      isNull,
    );
    expect(
      tester.widget<CheckboxListTile>(key('sync-merge-consent')).onChanged,
      isNull,
    );
    await tap(tester, key('sync-retry'));
    expect(owner.retries, 1);
    expect(owner.confirmations.length, 1);
    await finish(tester, owner);
  });

  testWidgets('cancel keeps both versions and never sends confirmation', (
    tester,
  ) async {
    final owner = CycleActionsFake(
      SyncCycleView(SyncCyclePhase.consent, preview: await uiPreview()),
    );
    await show(tester, owner);
    await tap(tester, key('sync-merge-cancel'));
    expect(owner.cancels, 1);
    expect(owner.confirmations, isEmpty);
    expect(find.text('Выбор отменён. Обе версии сохранены.'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-merge-confirm')), findsNothing);
    await finish(tester, owner);
  });

  testWidgets(
    'missing base and legacy metadata limitation are explicit without key bytes',
    (tester) async {
      final owner = CycleActionsFake(
        SyncCycleView(
          SyncCyclePhase.consent,
          preview: await uiPreview(legacy: true, missingBase: true),
        ),
      );
      await show(tester, owner);
      expect(
        find.textContaining('Исходная общая версия недоступна'),
        findsOneWidget,
      );
      expect(
        find.textContaining('проверена только открытая метаинформация'),
        findsOneWidget,
      );
      expect(find.textContaining('credential-private-sentinel'), findsNothing);
      expect(find.textContaining('SD1-'), findsNothing);
      await finish(tester, owner);
    },
  );

  testWidgets(
    'conflict reasons are paged as metadata and show more has its own callback',
    (tester) async {
      final owner = CycleActionsFake(
        SyncCycleView(
          SyncCyclePhase.conflict,
          preview: await uiPreview(conflicts: 25),
        ),
      );
      await show(tester, owner);
      expect(find.byType(DeckListItem), findsNWidgets(20));
      await tap(tester, find.text('Показать ещё'));
      expect(find.byType(DeckListItem), findsNWidgets(25));
      expect(find.textContaining('private-remote-name'), findsNothing);
      expect(owner.confirmations, isEmpty);
      await finish(tester, owner);
    },
  );

  testWidgets(
    'pending action and owner replacement ignore old completion and keep new consent separate',
    (tester) async {
      final old = CycleActionsFake(
        SyncCycleView(SyncCyclePhase.consent, preview: await uiPreview()),
      );
      final gate = Completer<void>();
      old.onConfirm = () => gate.future;
      await show(tester, old);
      await tap(tester, key('sync-merge-consent'));
      await tap(tester, key('sync-merge-confirm'));
      expect(
        tester.widget<DeckButton>(key('sync-merge-confirm')).onPressed,
        isNull,
      );
      final next = CycleActionsFake(
        SyncCycleView(SyncCyclePhase.consent, preview: await uiPreview()),
      );
      await show(tester, next);
      gate.completeError(StateError('private-error-sentinel'));
      await tester.pumpAndSettle();
      expect(find.textContaining('private-error-sentinel'), findsNothing);
      expect(
        tester.widget<CheckboxListTile>(key('sync-merge-consent')).value,
        isFalse,
      );
      expect(next.confirmations, isEmpty);
      await finish(tester, next);
      await old.dispose();
    },
  );

  testWidgets(
    'locked and active statuses disable retry; unknown failure has no raw code',
    (tester) async {
      final owner = CycleActionsFake(
        const SyncCycleView(SyncCyclePhase.waitingForKey),
      );
      await show(tester, owner);
      expect(tester.widget<DeckButton>(key('sync-retry')).onPressed, isNull);
      owner.emit(const SyncCycleView(SyncCyclePhase.publishing));
      await tester.pumpAndSettle();
      expect(tester.widget<DeckButton>(key('sync-retry')).onPressed, isNull);
      owner.emit(
        const SyncCycleView(
          SyncCyclePhase.error,
          errorCode: 'private-code-sentinel',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('private-code-sentinel'), findsNothing);
      expect(find.text('Синхронизация требует внимания.'), findsOneWidget);
      expect(tester.widget<DeckButton>(key('sync-retry')).onPressed, isNotNull);
      await finish(tester, owner);
    },
  );
}
