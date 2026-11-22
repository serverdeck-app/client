import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../ui/deck_components.dart';
import 'sync_owner.dart';
import 'sync_origin.dart';
import 'sync_repository.dart';
import 'sync_transport.dart';
import 'sync_wire.dart';

enum _LeaveIntent { logout, switchAccount, revoke, reset, rebind }

String _seen(int seconds) {
  try {
    final time = DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
      isUtc: true,
    ).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  } catch (_) {
    return 'Дата недоступна';
  }
}

/// C02/C03/C07/C10/C11/C12/C13/C14/C17/C18/C24/C25 lifecycle actions.
/// Owns only presentation/unchecked consent; native capabilities own authority.
class SyncDeviceView extends StatefulWidget {
  const SyncDeviceView({
    super.key,
    required this.owner,
    this.normalizeOrigin = normalizeSyncServiceOrigin,
  });
  final SyncOwner owner;
  final SyncOriginNormalizer normalizeOrigin;
  @override
  State<SyncDeviceView> createState() => _SyncDeviceViewState();
}

class _SyncDeviceViewState extends State<SyncDeviceView> {
  final _nextOrigin = TextEditingController();
  bool _editingOrigin = false;
  StreamSubscription<SyncAuthView>? _subscription;
  List<SyncRemoteDevice>? _devices;
  SyncDisconnectPreview? _preview;
  SyncDetachedPreview? _detached;
  SyncDisconnectResult? _result;
  SyncServiceOrigin? _leftOrigin;
  _LeaveIntent _intent = _LeaveIntent.logout;
  bool _busy = false,
      _clear = false,
      _discard = false,
      _consent = false,
      _discardConsent = false;
  String? _error, _notice, _binding;
  int _work = 0;
  SyncAccountLifecycle? get _lifecycle => widget.owner.lifecycle;
  String _identity() => widget.owner.repository.domain.read((r) {
    final s = r.syncState;
    return '${s.identityGeneration}/${s.serviceOrigin}/${s.accountId}/${s.deviceId}/${s.vaultId}/${s.enabled}';
  });
  bool _current(SyncOwner owner, int work) =>
      mounted && identical(owner, widget.owner) && work == _work;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _work++;
    _editingOrigin = false;
    _nextOrigin.clear();
    _busy = false;
    _devices = null;
    _preview = null;
    _detached = null;
    _result = null;
    _leftOrigin = null;
    _error = null;
    _notice = null;
    _clear = _discard = _consent = _discardConsent = false;
    _binding = _identity();
    final owner = widget.owner;
    _subscription = owner.changes.listen((_) {
      if (!mounted || !identical(owner, widget.owner)) return;
      final binding = _identity();
      if (binding != _binding) {
        _binding = binding;
        _devices = null;
        _error = null;
        _notice = null;
        _result = null;
        _preview = null;
        _detached = null;
        _consent = _discardConsent = false;
      }
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(SyncDeviceView old) {
    super.didUpdateWidget(old);
    if (!identical(old.owner, widget.owner)) {
      unawaited(_subscription?.cancel());
      _bind();
    }
  }

  @override
  void dispose() {
    _work++;
    unawaited(_subscription?.cancel());
    _nextOrigin.dispose();
    super.dispose();
  }

  String _business() => widget.owner.repository.domain.read((r) {
    final s = r.syncState;
    return '${s.serviceOrigin}/${s.accountId}/${s.deviceId}/${s.vaultId}';
  });

  Future<void> _run(
    Future<void> Function(SyncOwner owner, int work) action, {
    bool allowAuthStop = false,
  }) async {
    if (_busy || (_lifecycle?.busy ?? false)) return;
    final owner = widget.owner, work = ++_work;
    final binding = _identity(), business = _business();
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action(owner, work);
    } catch (error) {
      if (_current(owner, work) &&
          (binding == _identity() || allowAuthStop && business == _business()))
        setState(() {
          _preview = null;
          _detached = null;
          _consent = _discardConsent = false;
          _error =
              error is OperationFailure && error.code == FailureCode.conflict
              ? 'План устарел. Прочитайте состояние заново и подтвердите новый выбор.'
              : 'Не удалось выполнить действие. Проверьте состояние и повторите попытку. Локальные данные не удаляются частично.';
        });
    } finally {
      if (_current(owner, work)) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() => _run((owner, work) async {
    final binding = _identity();
    setState(() => _devices = null);
    final devices = await owner.listDevices();
    if (_current(owner, work) && binding == _identity())
      setState(() => _devices = devices);
  });
  Future<void> _status() => _run((owner, work) async {
    final status = await owner.checkDeviceStatus();
    if (_current(owner, work))
      setState(() {
        _devices = null;
        if (status == SyncDeviceStatus.active) _notice = 'Устройство активно. Это не заменяет вход или разблокировку хранилища.';
      });
  });
  Future<void> _web({SyncServiceOrigin? origin}) => _run((owner, work) async {
    await owner.openDeviceManagement(service: origin);
  });
  SyncServiceOrigin? _validatedNextOrigin() {
    try {
      return widget.normalizeOrigin(_nextOrigin.text);
    } catch (_) {
      return null;
    }
  }

  Future<void> _leave(_LeaveIntent intent, {SyncServiceOrigin? nextOrigin}) =>
      _run((owner, work) async {
        final binding = _identity();
        final preview = await owner.lifecycle!.preview(nextOrigin: nextOrigin);
        if (_current(owner, work) && binding == _identity())
          setState(() {
            _intent = intent;
            _preview = preview;
            _detached = null;
            _clear = _discard = _consent = _discardConsent = false;
            _result = null;
          });
      });
  Future<void> _confirm() async {
    final preview = _preview;
    if (preview == null ||
        !_consent ||
        (!_clear && preview.requiresPreviousResolution && !_discard))
      return;
    final clear = _clear, discard = _discard, intent = _intent;
    await _run((owner, work) async {
      final before = owner.repository.domain.read(
        (r) => r.syncState.identityGeneration,
      );
      final pending =
          owner.repository.domain.read((r) => r.syncState.errorCode) ==
          syncDisconnectPending;
      final result = await owner.lifecycle!.disconnect(
        preview,
        choice: clear ? SyncLocalDataChoice.clear : SyncLocalDataChoice.keep,
        discardPreviousDetached: discard,
        revokeSelf: intent == _LeaveIntent.revoke,
      );
      final ownCompletion = owner.repository.domain.read(
        (r) =>
            !r.syncState.enabled &&
            r.syncState.accountId == null &&
            r.syncState.identityGeneration == before + (pending ? 1 : 2),
      );
      if (_current(owner, work))
        setState(() {
          _preview = null;
          _detached = null;
          _consent = _discardConsent = false;
          _devices = null;
          if (ownCompletion) {
            _binding = _identity();
            _editingOrigin = false;
            _nextOrigin.clear();
            _result = result;
            _leftOrigin = SyncServiceOrigin(preview.identity.serviceOrigin);
          }
        });
    }, allowAuthStop: true);
  }

  Future<void> _readDetached() => _run((owner, work) async {
    final binding = _identity();
    final preview = await owner.lifecycle!.previewDetached();
    if (_current(owner, work) && binding == _identity())
      setState(() {
        _preview = null;
        _detached = preview;
        _discardConsent = false;
      });
  });
  Future<void> _discardDetached() async {
    final preview = _detached;
    if (preview == null || !_discardConsent || preview.count == 0) return;
    await _run((owner, work) async {
      final binding = _identity();
      final reclaimed = await owner.lifecycle!.discardDetached(preview);
      if (_current(owner, work) && binding == _identity())
        setState(() {
          _detached = null;
          _discardConsent = false;
          _notice = reclaimed ? 'Старая ожидающая копия удалена.' : 'Старая ожидающая копия отсоединена. Очистка кэша не завершена.';
        });
    });
  }

  Future<void> _reclaim() => _run((owner, work) async {
    final binding = _identity();
    final reclaimed = await owner.lifecycle!.reclaimCache();
    if (_current(owner, work) && binding == _identity())
      setState(
        () => _notice = reclaimed
            ? 'Очистка неиспользуемого кэша завершена. Сохранённые ожидающие копии оставлены.'
            : 'Очистка кэша не завершена. Повторите попытку; сохранённые копии не удалены.',
      );
  });

  @override
  Widget build(BuildContext context) {
    final owner = widget.owner, life = _lifecycle, phase = owner.view.phase;
    final bound = owner.repository.domain.read((r) => r.syncState.enabled);
    final ready =
        !_busy &&
        !(life?.busy ?? false) &&
        phase != SyncAuthPhase.paused &&
        !{
          SyncAuthPhase.starting,
          SyncAuthPhase.awaitingApproval,
          SyncAuthPhase.protecting,
        }.contains(phase);
    final currentDevice = owner.repository.domain.read(
      (r) => r.syncState.deviceId,
    );
    final nextOrigin = _validatedNextOrigin();
    final currentOrigin = owner.repository.domain.read(
      (r) => r.syncState.serviceOrigin,
    );
    final preview = _preview, detached = _detached, result = _result;
    return DeckFormSection(
      title: 'Устройства и управление аккаунтом',
      children: [
        const Text(
          'Отзыв запрещает будущую синхронизацию, но не гарантирует удаление уже скачанных данных. При компрометации замените SSH-пароли и ключи на серверах.',
        ),
        if (_error != null) DeckNotice(message: _error!, tone: DeckTone.error),
        if (_notice != null) DeckNotice(message: _notice!),
        if (phase == SyncAuthPhase.revoked)
          const DeckNotice(
            message: 'Доступ этого устройства отозван. Локальные SSH-данные сохранены. Для возврата нужен новый вход.',
          ),
        if (phase == SyncAuthPhase.vaultReset)
          const DeckNotice(
            message: 'Хранилище сброшено. Старый код не откроет новое хранилище. Потребуются новый вход, новый ключ и отдельное подтверждение импорта локальных данных.',
            tone: DeckTone.warning,
          ),
        if (phase == SyncAuthPhase.disconnectRequired)
          const DeckNotice(
            message: 'Завершите локальный выход: выберите сохранение или удаление локальных данных. Повторный вход пока заблокирован.',
            tone: DeckTone.warning,
          ),
        if (bound)
          DeckActions(
            children: [
              DeckButton(
                key: const ValueKey('sync-devices-refresh'),
                onPressed: ready && phase == SyncAuthPhase.signedIn
                    ? _refresh
                    : null,
                child: const Text('Обновить устройства'),
              ),
              DeckButton(
                key: const ValueKey('sync-device-status'),
                onPressed: ready && phase != SyncAuthPhase.disconnectRequired
                    ? _status
                    : null,
                child: const Text('Проверить доступ устройства'),
              ),
              DeckButton(
                key: const ValueKey('sync-devices-web'),
                onPressed: ready ? _web : null,
                child: const Text('Устройства и сброс в браузере'),
              ),
            ],
          ),
        if (_devices != null) ...[
          Text('Активных устройств: ${_devices!.length} из 10'),
          if (_devices!.isEmpty) const Text('Активные устройства не найдены.'),
          for (final device in _devices!)
            DeckFormSection(
              title: device.name,
              children: [
                if (device.id == currentDevice) const Text('Это устройство'),
                DeckKeyValue(label: 'ID устройства', value: device.id),
                DeckKeyValue(
                  label: 'Платформа',
                  value: device.platform == 'windows' ? 'Windows' : 'Android',
                ),
                DeckKeyValue(
                  label: 'Последняя активность',
                  value: _seen(device.lastSeenAt),
                ),
                if (device.id != currentDevice)
                  DeckButton(
                    key: ValueKey('sync-device-web-${device.id}'),
                    onPressed: ready ? _web : null,
                    child: const Text('Отозвать в браузере'),
                  ),
              ],
            ),
        ],
        if (bound && life != null && preview == null)
          DeckActions(
            children: [
              DeckButton(
                key: const ValueKey('sync-logout'),
                onPressed: ready ? () => _leave(_LeaveIntent.logout) : null,
                child: const Text('Выйти из синхронизации'),
              ),
              DeckButton(
                key: const ValueKey('sync-switch-account'),
                onPressed: ready
                    ? () => _leave(_LeaveIntent.switchAccount)
                    : null,
                child: const Text('Сменить аккаунт'),
              ),
              DeckButton(
                key: const ValueKey('sync-self-revoke'),
                onPressed: ready ? () => _leave(_LeaveIntent.revoke) : null,
                child: const Text('Отозвать это устройство'),
              ),
              if (phase == SyncAuthPhase.vaultReset)
                DeckButton(
                  key: const ValueKey('sync-reset-reconnect'),
                  onPressed: ready ? () => _leave(_LeaveIntent.reset) : null,
                  child: const Text('Подключиться к новому хранилищу'),
                ),
            ],
          ),
        if (bound && life != null && preview == null) ...[
          DeckButton(
            key: const ValueKey('sync-change-service'),
            onPressed: ready
                ? () => setState(() {
                    _editingOrigin = true;
                    _error = null;
                  })
                : null,
            child: const Text('Сменить сервис синхронизации'),
          ),
          if (_editingOrigin) ...[
            DeckTextField(
              key: const ValueKey('sync-next-origin'),
              label: 'Адрес нового сервиса',
              controller: _nextOrigin,
              enabled: ready,
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {
                _consent = false;
                _error = null;
              }),
              error: _nextOrigin.text.isNotEmpty && nextOrigin == null
                  ? 'Нужен HTTPS-адрес без пути, логина и параметров.'
                  : null,
            ),
            if (nextOrigin != null)
              DeckKeyValue(label: 'Новый сервис', value: nextOrigin.value),
            const Text(
              'Ввод адреса не передаёт данные. Перед подключением к новому сервису нужно завершить старую привязку; выбор локальной копии будет показан отдельно.',
            ),
            DeckActions(
              children: [
                DeckButton(
                  key: const ValueKey('sync-rebind-preview'),
                  onPressed:
                      ready &&
                          nextOrigin != null &&
                          nextOrigin.value != currentOrigin
                      ? () =>
                            _leave(_LeaveIntent.rebind, nextOrigin: nextOrigin)
                      : null,
                  child: const Text('Проверить смену сервиса'),
                ),
                DeckButton(
                  key: const ValueKey('sync-rebind-cancel'),
                  onPressed: ready
                      ? () => setState(() {
                          _editingOrigin = false;
                          _nextOrigin.clear();
                        })
                      : null,
                  child: const Text('Отменить смену сервиса'),
                ),
              ],
            ),
          ],
        ],
        if (preview != null) ...[
          Text(switch (_intent) {
            _LeaveIntent.logout => 'Подтвердите выход',
            _LeaveIntent.switchAccount => 'Подготовка смены аккаунта',
            _LeaveIntent.revoke => 'Отзыв этого устройства',
            _LeaveIntent.reset => 'Подключение после сброса',
            _LeaveIntent.rebind => 'Смена сервиса синхронизации',
          }),
          Text(
            'Серверов: ${preview.profileCount}; карточек ПО: ${preview.cardCount}',
          ),
          Text(
            'Ожидающих изменений: ${preview.pendingChanges}; активных копий: ${preview.activeRoots}; старых копий: ${preview.detachedRoots}',
          ),
          if (preview.nextOrigin != null) ...[
            DeckKeyValue(
              label: 'Прежний сервис',
              value: preview.identity.serviceOrigin,
            ),
            DeckKeyValue(
              label: 'Новый сервис',
              value: preview.nextOrigin!.value,
            ),
            const Text(
              'Старые токены и ключ синхронизации не попадут в новый сервис. Для него нужны новый вход, разблокировка и отдельное согласие на импорт.',
            ),
          ],
          const Text(
            'Синхронизация остановится, локальные токены и ключ синхронизации будут удалены. По умолчанию SSH-данные и подключения сохраняются.',
          ),
          if (_intent == _LeaveIntent.switchAccount ||
              _intent == _LeaveIntent.reset ||
              _intent == _LeaveIntent.rebind)
            const Text(
              'Сохранённая копия остаётся локально. В новом аккаунте потребуется отдельный план и согласие на импорт. После сброса нужен новый ключ; старые зашифрованные копии не переносятся.',
            ),
          CheckboxListTile(
            key: const ValueKey('sync-clear-local'),
            value: _clear,
            onChanged: ready
                ? (value) => setState(() {
                    _clear = value ?? false;
                    _consent = false;
                  })
                : null,
            title: const Text(
              'Удалить локальные SSH-серверы, credentials, карточки ПО и связанные локальные данные',
            ),
          ),
          if (_clear)
            const DeckNotice(
              message: 'Локальные SSH-подключения будут закрыты; профили, пароли, приватные ключи, карточки и их история удалятся с этого устройства. Данные сервиса и других устройств не удаляются.',
              tone: DeckTone.warning,
            ),
          if (preview.requiresPreviousResolution && !_clear)
            CheckboxListTile(
              key: const ValueKey('sync-discard-previous'),
              value: _discard,
              onChanged: ready
                  ? (value) => setState(() {
                      _discard = value ?? false;
                      _consent = false;
                    })
                  : null,
              title: const Text(
                'Удалить ранее отсоединённую ожидающую копию, чтобы сохранить текущую',
              ),
            ),
          const Text(
            'Ожидающие копии сохраняются отсоединёнными при выборе сохранения. Без старого кода их нельзя расшифровать; текущие локальные SSH-данные доступны независимо от них.',
          ),
          CheckboxListTile(
            key: const ValueKey('sync-disconnect-consent'),
            value: _consent,
            onChanged: ready
                ? (value) => setState(() => _consent = value ?? false)
                : null,
            title: const Text(
              'Подтверждаю показанный состав и последствия выбранного действия',
            ),
          ),
          DeckActions(
            children: [
              DeckButton(
                key: const ValueKey('sync-disconnect-confirm'),
                kind: DeckButtonKind.primary,
                onPressed:
                    ready &&
                        _consent &&
                        (_clear ||
                            !preview.requiresPreviousResolution ||
                            _discard)
                    ? _confirm
                    : null,
                pending: _busy,
                child: const Text('Подтвердить действие'),
              ),
              DeckButton(
                key: const ValueKey('sync-disconnect-cancel'),
                onPressed: ready
                    ? () => setState(() {
                        _preview = null;
                        _consent = false;
                      })
                    : null,
                child: const Text('Отмена'),
              ),
            ],
          ),
        ],
        if (result != null) ...[
          const DeckNotice(
            message: 'Локальный выход завершён. Синхронизация остановлена.',
          ),
          Text(
            result.remoteConfirmed
                ? 'Сервис подтвердил отзыв этого устройства.'
                : 'Сервис не подтвердил отзыв. Устройство может оставаться активным в сервисе; проверьте его в браузере.',
          ),
          if (!result.cacheReclaimed)
            const Text(
              'Очистка неиспользуемого кэша не завершена. Её можно повторить без входа.',
            ),
        ],
        if (_leftOrigin != null)
          DeckButton(
            key: const ValueKey('sync-left-service-web'),
            onPressed: ready ? () => _web(origin: _leftOrigin) : null,
            child: const Text('Проверить прежний сервис в браузере'),
          ),
        if (life != null && preview == null)
          DeckButton(
            key: const ValueKey('sync-detached-preview'),
            onPressed: ready ? _readDetached : null,
            child: const Text('Проверить старые ожидающие копии'),
          ),
        if (detached != null) ...[
          Text('Старых ожидающих копий: ${detached.count}'),
          if (detached.origin != null)
            DeckKeyValue(label: 'Сервис старой копии', value: detached.origin!),
          if (detached.accountId != null)
            DeckKeyValue(
              label: 'Аккаунт старой копии',
              value: detached.accountId!,
            ),
          const Text(
            'Удаление старой ожидающей копии необратимо. Текущие локальные серверы и данные сервиса сохранятся.',
          ),
          CheckboxListTile(
            key: const ValueKey('sync-detached-consent'),
            value: _discardConsent,
            onChanged: ready && detached.count > 0
                ? (value) => setState(() => _discardConsent = value ?? false)
                : null,
            title: const Text('Удалить показанные старые ожидающие копии'),
          ),
          DeckActions(
            children: [
              DeckButton(
                key: const ValueKey('sync-detached-delete'),
                onPressed: ready && _discardConsent && detached.count > 0
                    ? _discardDetached
                    : null,
                child: const Text('Удалить старые копии'),
              ),
              DeckButton(
                key: const ValueKey('sync-detached-cancel'),
                onPressed: ready
                    ? () => setState(() {
                        _detached = null;
                        _discardConsent = false;
                      })
                    : null,
                child: const Text('Отмена'),
              ),
            ],
          ),
        ],
        if (life != null && !bound)
          DeckButton(
            key: const ValueKey('sync-cache-reclaim'),
            onPressed: ready ? _reclaim : null,
            child: const Text('Повторить очистку кэша'),
          ),
        const Text(
          'Отзыв других устройств и сброс облачного хранилища выполняются в браузере с повторным входом через VK ID. Веб-страница не получает ваши SSH-секреты или код восстановления.',
        ),
      ],
    );
  }
}
