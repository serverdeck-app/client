import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/deck_components.dart';
import 'sync_owner.dart';
import 'device_view.dart';
import 'sync_origin.dart';
export 'sync_origin.dart' show SyncOriginNormalizer, normalizeSyncServiceOrigin;
import 'sync_cycle.dart';
import 'sync_merge.dart';
import 'sync_wire.dart';
import '../domain/models.dart';
import 'sync_recovery.dart';
import 'sync_key_transfer.dart';
import 'sync_qr_camera.dart';
import 'sync_qr_view.dart';

String _recoveryError(String? code) => switch (code) {
  'INVALID_ARGUMENT' => 'Код не подходит или данные хранилища повреждены.',
  'PROTECTION_UNAVAILABLE' => 'Локальная защита недоступна. Используйте код восстановления или повторите попытку.',
  'AUTH_REQUIRED' => 'Сначала войдите в аккаунт.',
  'CONFLICT' => 'Хранилище изменилось. Проверьте его заново.',
  'CLEANUP_REQUIRED' => 'Ожидающие локальные данные используют другой ключ. Сначала выберите их сохранение или импорт в управлении аккаунтом.',
  'UNSUPPORTED_CONTENT_VERSION' =>
    'Для этого хранилища нужна новая версия приложения.',
  'NETWORK_ERROR' ||
  'TIMEOUT' => 'Сервис недоступен. Локальные данные сохранены.',
  _ => 'Не удалось открыть хранилище. Локальные данные не изменены.',
};

/// C02/C03/C10/C11/C12/C13/C14/C16/C17/C18/C24 recovery section. Account/login,
/// consent, conflicts and devices compose around this in their own story tasks.
class SyncRecoveryView extends StatefulWidget {
  const SyncRecoveryView({
    super.key,
    required this.owner,
    this.platform = 'windows',
    this.createCameraDriver,
  });
  final SyncVaultOwner owner;
  final String platform;
  final SyncQrCameraDriver Function()? createCameraDriver;
  @override
  State<SyncRecoveryView> createState() => _SyncRecoveryViewState();
}

class _SyncRecoveryViewState extends State<SyncRecoveryView>
    with WidgetsBindingObserver {
  StreamSubscription<SyncVaultView>? _subscription;
  final _routes =
      <
        (
          SyncVaultOwner,
          DialogRoute<void>,
          NavigatorState,
          SyncRecoveryChallenge?,
        )
      >{};
  bool _busy = false;
  bool _qrError = false;
  int _qrIntent = 0;
  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.platform == 'windows' && state != AppLifecycleState.resumed)
      _qrIntent++;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listen();
  }

  void _listen() {
    final owner = widget.owner;
    _subscription = owner.changes.listen((view) {
      if (!mounted || owner != widget.owner) return;
      if (view.phase == SyncVaultPhase.unavailable ||
          view.phase == SyncVaultPhase.ready)
        _closeRoutes();
      setState(() {});
    });
  }

  void _closeRoutes() {
    final routes = List.of(_routes);
    _routes.clear();
    for (final (owner, _, _, challenge) in routes) {
      if (challenge != null)
        owner.cancelInitialization(challenge);
      else if (owner.view.phase == SyncVaultPhase.unlocking)
        owner.lock();
    }
    if (routes.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final (_, route, navigator, _) in routes) {
        if (route.isActive && navigator.mounted) navigator.removeRoute(route);
      }
    });
  }

  void _cancelPending(SyncVaultOwner owner) {
    if (_busy &&
        {
          SyncVaultPhase.checking,
          SyncVaultPhase.unlocking,
          SyncVaultPhase.awaitingConfirmation,
        }.contains(owner.view.phase))
      owner.lock();
  }

  @override
  void didUpdateWidget(SyncRecoveryView old) {
    super.didUpdateWidget(old);
    if (old.owner != widget.owner) {
      _qrIntent++;
      unawaited(_subscription?.cancel());
      _closeRoutes();
      _cancelPending(old.owner);
      _busy = false;
      _listen();
    }
  }

  @override
  void dispose() {
    _qrIntent++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    _closeRoutes();
    _cancelPending(widget.owner);
    super.dispose();
  }

  Future<void> _inspect() async {
    if (_busy) return;
    final owner = widget.owner;
    setState(() => _busy = true);
    try {
      await owner.inspect();
    } catch (_) {
      /* Safe owner error projection. */
    } finally {
      if (mounted && owner == widget.owner) setState(() => _busy = false);
    }
  }

  Future<void> _dialog({required bool initialize}) async {
    if (_busy) return;
    final owner = widget.owner, navigator = Navigator.of(context);
    setState(() => _busy = true);
    SyncRecoveryChallenge? challenge;
    try {
      if (initialize) challenge = await owner.beginInitialization();
      if (!mounted || owner != widget.owner || challenge?.disposed == true)
        return;
      final code = challenge?.code;
      final draft = challenge;
      final route = DialogRoute<void>(
        context: context,
        builder: (_) =>
            _RecoveryDialog(owner: owner, challenge: draft, code: code),
      );
      final entry = (owner, route, navigator, challenge);
      _routes.add(entry);
      try {
        await navigator.push(route);
      } finally {
        _routes.remove(entry);
      }
    } catch (_) {
      /* No raw error or recovery code in ordinary projections. */
    } finally {
      if (challenge != null) owner.cancelInitialization(challenge);
      if (mounted && owner == widget.owner) setState(() => _busy = false);
    }
  }

  Future<void> _qr({required bool scan}) async {
    if (_busy) return;
    if (!scan && !_foreground) return;
    final intent = ++_qrIntent;
    final owner = widget.owner, navigator = Navigator.of(context);
    final generation = owner.actionGeneration;
    setState(() {
      _busy = true;
      _qrError = false;
    });
    SyncKeyTransfer? transfer;
    var manual = false;
    try {
      final capture = scan ? owner.captureQrImport() : null;
      if (!scan) transfer = await owner.exportQr();
      if (!mounted ||
          owner != widget.owner ||
          owner.actionGeneration != generation ||
          !scan && (intent != _qrIntent || !_foreground))
        return;
      final secret = transfer;
      final route = DialogRoute<void>(
        context: context,
        builder: (_) => SyncQrDialog(
          owner: owner,
          transfer: secret,
          capture: capture,
          canDisplay: scan
              ? null
              : () =>
                    mounted &&
                    owner == widget.owner &&
                    intent == _qrIntent &&
                    _foreground,
          createCameraDriver: widget.createCameraDriver,
          onManual: () => manual = true,
        ),
      );
      final entry = (owner, route, navigator, null);
      _routes.add(entry);
      try {
        await navigator.push(route);
      } finally {
        _routes.remove(entry);
      }
    } catch (_) {
      if (mounted && owner == widget.owner) setState(() => _qrError = true);
    } finally {
      transfer?.dispose();
      if (mounted && owner == widget.owner) setState(() => _busy = false);
    }
    if (manual && mounted && owner == widget.owner)
      await _dialog(initialize: false);
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.owner.view;
    final message = switch (view.phase) {
      SyncVaultPhase.unavailable => 'Хранилище ещё не проверено.',
      SyncVaultPhase.checking => 'Проверяем защищённое хранилище…',
      SyncVaultPhase.needsInitialization =>
        'В облаке пока нет данных. Создайте и сохраните код восстановления.',
      SyncVaultPhase.awaitingConfirmation =>
        'Сохраните код в отдельном окне и подтвердите контрольные символы.',
      SyncVaultPhase.locked => 'Для разблокировки нужен код восстановления.',
      SyncVaultPhase.unlocking => 'Разблокировка хранилища…',
      SyncVaultPhase.ready => 'Хранилище разблокировано.',
      SyncVaultPhase.error => _recoveryError(view.errorCode),
    };
    return DeckFormSection(
      title: 'Шифрование и восстановление',
      children: [
        DeckStatus(
          label: message,
          tone: view.phase == SyncVaultPhase.error
              ? DeckTone.error
              : view.phase == SyncVaultPhase.ready
              ? DeckTone.success
              : DeckTone.neutral,
        ),
        const Text(
          'Разблокировка не заменяет согласие на синхронизацию. Код восстановления не передаётся сервису.',
        ),
        if (_qrError)
          const DeckNotice(
            message: 'Не удалось подготовить QR. Сначала синхронизируйте и проверьте хранилище.',
            tone: DeckTone.error,
          ),
        DeckActions(
          children: [
            if (widget.platform == 'windows' &&
                view.phase == SyncVaultPhase.ready)
              DeckButton(
                onPressed: _busy ? null : () => _qr(scan: false),
                child: const Text('Показать QR для Android'),
              ),
            if (widget.platform == 'android' &&
                (view.phase == SyncVaultPhase.locked ||
                    view.phase == SyncVaultPhase.error &&
                        (view.revision ?? 0) > 0))
              DeckButton(
                onPressed: _busy ? null : () => _qr(scan: true),
                child: const Text('Сканировать QR'),
              ),
            if ({
              SyncVaultPhase.unavailable,
              SyncVaultPhase.error,
            }.contains(view.phase))
              DeckButton(
                onPressed: _busy ? null : _inspect,
                child: const Text('Проверить хранилище'),
              ),
            if (view.phase == SyncVaultPhase.needsInitialization)
              DeckButton(
                onPressed: _busy ? null : () => _dialog(initialize: true),
                child: const Text('Создать код восстановления'),
              ),
            if (view.phase == SyncVaultPhase.locked ||
                view.phase == SyncVaultPhase.error && (view.revision ?? 0) > 0)
              DeckButton(
                onPressed: _busy ? null : () => _dialog(initialize: false),
                child: const Text('Ввести код восстановления'),
              ),
            if ({
              SyncVaultPhase.checking,
              SyncVaultPhase.awaitingConfirmation,
              SyncVaultPhase.unlocking,
            }.contains(view.phase))
              DeckButton(
                onPressed: widget.owner.lock,
                child: const Text('Отменить'),
              ),
          ],
        ),
      ],
    );
  }
}

class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog({required this.owner, this.challenge, this.code});
  final SyncVaultOwner owner;
  final SyncRecoveryChallenge? challenge;
  final String? code;
  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  final _input = TextEditingController();
  bool _saved = false, _busy = false;
  String? _error;
  void _cancelOperation() {
    final challenge = widget.challenge;
    if (challenge != null)
      widget.owner.cancelInitialization(challenge);
    else if (widget.owner.view.phase == SyncVaultPhase.unlocking)
      widget.owner.lock();
  }

  @override
  void dispose() {
    _cancelOperation();
    _input.clear();
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final owner = widget.owner;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final challenge = widget.challenge;
      if (challenge != null)
        await owner.confirmInitialization(
          challenge,
          saved: _saved,
          checksum: _input.text,
        );
      else
        await owner.unlock(_input.text);
      if (mounted) {
        _input.clear();
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted)
        setState(
          () => _error =
              widget.challenge != null &&
                  owner.view.phase == SyncVaultPhase.awaitingConfirmation
              ? 'Контрольные символы не совпали.'
              : _recoveryError(owner.view.errorCode),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final initialize = widget.challenge != null;
    final canSubmit =
        !_busy &&
        (initialize
            ? _saved && RegExp(r'^[0-9a-f]{8}$').hasMatch(_input.text.trim())
            : _input.text.trim().isNotEmpty);
    return DeckDialogLayout(
      title: initialize
          ? 'Сохраните код восстановления'
          : 'Разблокировать хранилище',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (initialize) ...[
            const Text(
              'Храните код в надёжном месте отдельно от устройства. Вход через VK не восстанавливает этот ключ.',
            ),
            SelectableText(widget.code!),
            CheckboxListTile(
              value: _saved,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _saved = value ?? false),
              title: const Text('Я сохранил код восстановления'),
            ),
          ],
          DeckTextField(
            key: const ValueKey('recovery-code-input'),
            label: initialize
                ? 'Последние 8 символов кода'
                : 'Код восстановления',
            controller: _input,
            secret: !initialize,
            enabled: !_busy,
            onChanged: (_) => setState(() {
              _error = null;
            }),
          ),
          if (_error != null)
            DeckNotice(message: _error!, tone: DeckTone.error),
        ],
      ),
      actions: [
        DeckButton(
          onPressed: () {
            _cancelOperation();
            Navigator.of(context).pop();
          },
          child: const Text('Отмена'),
        ),
        DeckButton(
          kind: DeckButtonKind.primary,
          onPressed: canSubmit ? _submit : null,
          child: Text(initialize ? 'Подтвердить сохранение' : 'Разблокировать'),
        ),
      ],
    );
  }
}

String _authError(String? code) => switch (code) {
  'NETWORK_ERROR' ||
  'TIMEOUT' => 'Сервис недоступен. Локальные данные сохранены.',
  'access_denied' => 'Подключение не подтверждено в браузере.',
  'expired_token' => 'Время подтверждения истекло. Начните вход заново.',
  'device_limit' => 'Достигнут лимит устройств. Проверьте устройства в вебе.',
  'PROTECTION_UNAVAILABLE' =>
    'Локальная защита недоступна. Повторите вход после её восстановления.',
  'CONFLICT' => 'Привязка аккаунта изменилась. Проверьте состояние заново.',
  'INVALID_ARGUMENT' => 'Ответ сервиса не подходит. Проверьте адрес сервиса.',
  _ => 'Не удалось завершить вход. Локальные данные сохранены.',
};

bool _loginInProgress(SyncAuthPhase phase) => {
  SyncAuthPhase.starting,
  SyncAuthPhase.awaitingApproval,
  SyncAuthPhase.protecting,
}.contains(phase);

/// C02/C03/C10/C11/C13/C17/C18 account section around the C24 recovery/choice flow.
/// Closing a view cancels only its unfinished login, never a running sync cycle.
class SyncAccountView extends StatefulWidget {
  const SyncAccountView({
    super.key,
    required this.owner,
    required this.platform,
    this.normalizeOrigin = normalizeSyncServiceOrigin,
    required this.defaultDeviceName,
  });
  final SyncOwner owner;
  final String platform, defaultDeviceName;
  final SyncOriginNormalizer normalizeOrigin;
  @override
  State<SyncAccountView> createState() => _SyncAccountViewState();
}

class _SyncAccountViewState extends State<SyncAccountView> {
  final _origin = TextEditingController(), _name = TextEditingController();
  StreamSubscription<SyncAuthView>? _subscription;
  bool _consent = false,
      _busy = false,
      _restoring = true,
      _startedLogin = false;
  String? _error;
  int _generation = 0;
  int? _bindingGeneration;
  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _generation++;
    _consent = false;
    _busy = false;
    _restoring = true;
    _error = null;
    _startedLogin = false;
    _origin.text =
        widget.owner.repository.domain.read((r) => r.syncState.serviceOrigin) ??
        '';
    _name.text = widget.defaultDeviceName;
    final owner = widget.owner;
    _bindingGeneration = owner.repository.domain.read(
      (r) => r.syncState.identityGeneration,
    );
    _subscription = owner.changes.listen((view) {
      if (!mounted || owner != widget.owner) return;
      final state = owner.repository.domain.read((r) => r.syncState);
      if (state.identityGeneration != _bindingGeneration) {
        _bindingGeneration = state.identityGeneration;
        _consent = false;
        if (state.serviceOrigin != null) _origin.text = state.serviceOrigin!;
      }
      if (!_loginInProgress(owner.view.phase) &&
          !owner.hasPendingLogin &&
          !_busy)
        _startedLogin = false;
      setState(() {});
    });
    unawaited(_restore(owner, _generation));
  }

  Future<void> _restore(SyncOwner owner, int generation) async {
    try {
      await owner.restoreSession();
    } catch (_) {
      if (mounted && owner == widget.owner && generation == _generation)
        setState(
          () => _error = 'Не удалось прочитать состояние аккаунта. Локальные данные сохранены.',
        );
    } finally {
      if (mounted && owner == widget.owner && generation == _generation)
        setState(() => _restoring = false);
    }
  }

  void _cancelOwnedLogin(SyncOwner owner) {
    // beginLogin can still await restoration before publishing a login phase.
    if (_startedLogin &&
        (_busy || owner.hasPendingLogin || _loginInProgress(owner.view.phase)))
      owner.cancelLogin();
    _startedLogin = false;
  }

  @override
  void didUpdateWidget(SyncAccountView old) {
    super.didUpdateWidget(old);
    if (old.owner != widget.owner) {
      unawaited(_subscription?.cancel());
      _cancelOwnedLogin(old.owner);
      _bind();
    }
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_subscription?.cancel());
    _cancelOwnedLogin(widget.owner);
    _origin.dispose();
    _name.dispose();
    super.dispose();
  }

  SyncServiceOrigin? _validatedOrigin() {
    try {
      return widget.normalizeOrigin(_origin.text);
    } catch (_) {
      return null;
    }
  }

  bool get _validName {
    try {
      SyncWire.deviceName(_name.text.trim());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _login() async {
    final origin = _validatedOrigin();
    if (_busy ||
        _restoring ||
        !_consent ||
        origin == null ||
        !_validName ||
        !{'windows', 'android'}.contains(widget.platform))
      return;
    final owner = widget.owner, generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _startedLogin = true;
    });
    try {
      await owner.beginLogin(
        origin: origin,
        platform: widget.platform,
        name: _name.text.trim(),
      );
    } catch (_) {
      if (mounted && owner == widget.owner && generation == _generation)
        setState(() => _error = _authError(owner.view.errorCode));
    } finally {
      if (mounted && owner == widget.owner && generation == _generation)
        setState(() => _busy = false);
    }
  }

  void _cancel() {
    _generation++;
    widget.owner.cancelLogin();
    setState(() {
      _busy = false;
      _startedLogin = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.owner.view;
    final bound = widget.owner.repository.domain.read(
      (r) => r.syncState.enabled,
    );
    final inProgress =
        _loginInProgress(view.phase) ||
        view.phase == SyncAuthPhase.paused && widget.owner.hasPendingLogin;
    final canLogin =
        !_restoring &&
        !inProgress &&
        {
          SyncAuthPhase.disabled,
          SyncAuthPhase.loginRequired,
          SyncAuthPhase.revoked,
          SyncAuthPhase.error,
        }.contains(view.phase);
    final enabled = canLogin && !_busy;
    final origin = _validatedOrigin();
    final message = _restoring
        ? 'Проверяем состояние аккаунта…'
        : switch (view.phase) {
            SyncAuthPhase.disabled => 'Синхронизация выключена. Локальные серверы доступны без аккаунта.',
            SyncAuthPhase.starting => 'Открываем вход через браузер…',
            SyncAuthPhase.awaitingApproval =>
              'Подтвердите подключение этого устройства в браузере.',
            SyncAuthPhase.protecting => 'Сохраняем защищённый вход…',
            SyncAuthPhase.signedIn => 'Вход выполнен.',
            SyncAuthPhase.disconnectRequired => 'Выход не завершён. Локальные данные сохранены. Завершите выход в управлении аккаунтом.',
            SyncAuthPhase.loginRequired =>
              view.errorCode == null
                  ? 'Для синхронизации нужен вход.'
                  : _authError(view.errorCode),
            SyncAuthPhase.revoked => 'Доступ устройства отозван. Локальные SSH-данные сохранены; при компрометации замените их на серверах.',
            SyncAuthPhase.vaultReset => 'Хранилище сброшено. Для синхронизации нужно подключиться к новому хранилищу. Локальные данные сохранены.',
            SyncAuthPhase.paused =>
              widget.owner.hasPendingLogin
                  ? 'Вход приостановлен. Продолжим после возврата из браузера.'
                  : 'Синхронизация приостановлена.',
            SyncAuthPhase.error => _authError(view.errorCode),
          };
    return DeckFormSection(
      title: 'Аккаунт и синхронизация',
      children: [
        DeckStatus(
          label: message,
          tone: view.phase == SyncAuthPhase.signedIn
              ? DeckTone.success
              : {
                  SyncAuthPhase.revoked,
                  SyncAuthPhase.vaultReset,
                  SyncAuthPhase.error,
                }.contains(view.phase)
              ? DeckTone.warning
              : DeckTone.neutral,
        ),
        if (_error != null) DeckNotice(message: _error!, tone: DeckTone.error),
        if (view.accountId != null)
          DeckKeyValue(label: 'Аккаунт', value: view.accountId!),
        if (view.deviceId != null)
          DeckKeyValue(label: 'Это устройство', value: view.deviceId!),
        if (canLogin || inProgress) ...[
          DeckTextField(
            key: const ValueKey('sync-service-origin'),
            label: 'Адрес сервиса',
            controller: _origin,
            keyboardType: TextInputType.url,
            enabled: enabled && !bound,
            helper: bound
                ? 'Вход привязан к этому сервису.'
                : 'HTTPS-адрес сервиса. Ввод адреса не передаёт ваши серверы.',
            error: _origin.text.isNotEmpty && origin == null
                ? 'Укажите HTTPS-адрес без пути, логина и параметров.'
                : null,
            onChanged: (_) => setState(() {
              _error = null;
              _consent = false;
            }),
          ),
          DeckTextField(
            key: const ValueKey('sync-device-name'),
            label: 'Имя этого устройства',
            controller: _name,
            enabled: enabled,
            error: _name.text.isNotEmpty && !_validName
                ? 'Введите имя до 100 символов без управляющих знаков.'
                : null,
            onChanged: (_) => setState(() => _error = null),
          ),
          if (origin != null)
            DeckKeyValue(label: 'Сервис для входа', value: origin.value),
          const Text(
            'Будут синхронизироваться SSH-профили, пароли, приватные ключи и карточки ПО в зашифрованном виде. Код восстановления, passphrase и доверие к SSH-ключам не передаются.',
          ),
          CheckboxListTile(
            key: const ValueKey('sync-enable-consent'),
            value: _consent,
            onChanged: enabled
                ? (value) => setState(() => _consent = value ?? false)
                : null,
            title: const Text('Подключить синхронизацию между устройствами'),
          ),
          if (view.userCode != null)
            DeckKeyValue(
              label: 'Код подключения',
              value: view.userCode!,
              selectable: true,
            ),
          if (view.userCode != null)
            const Text(
              'Сверьте код, имя и платформу устройства в браузере. Вход сам по себе не разрешает заменять ваши данные.',
            ),
          DeckActions(
            children: [
              if (canLogin)
                DeckButton(
                  key: const ValueKey('sync-login'),
                  kind: DeckButtonKind.primary,
                  onPressed:
                      enabled &&
                          _consent &&
                          origin != null &&
                          _validName &&
                          {'windows', 'android'}.contains(widget.platform)
                      ? _login
                      : null,
                  pending: _busy,
                  child: const Text('Войти через браузер'),
                ),
              if (inProgress)
                DeckButton(
                  key: const ValueKey('sync-cancel-login'),
                  onPressed: _cancel,
                  child: const Text('Отменить вход'),
                ),
            ],
          ),
        ],
        if (widget.owner.lifecycle != null)
          SyncDeviceView(
            owner: widget.owner,
            normalizeOrigin: widget.normalizeOrigin,
          ),
        if (view.phase == SyncAuthPhase.signedIn) ...[
          SyncRecoveryView(
            owner: widget.owner.vault,
            platform: widget.platform,
          ),
          if (widget.owner.cycle != null)
            SyncStatusView(owner: widget.owner.cycle!),
        ],
      ],
    );
  }
}

String _cycleError(String? code) => switch (code) {
  'NETWORK_ERROR' || 'TIMEOUT' =>
    'Сервис недоступен. Локальные данные и ожидающие изменения сохранены.',
  'CONTENT_UPDATE_REQUIRED' || 'unsupported_content_version' => 'Обновите приложение, чтобы прочитать эту версию данных. Сбрасывать хранилище не нужно.',
  'RESOURCE_EXHAUSTED' ||
  'resource_exhausted' ||
  'STORAGE_UNAVAILABLE' ||
  'storage_unavailable' => 'Не хватает места или хранилище недоступно. Освободите место и повторите синхронизацию.',
  'PROTECTION_UNAVAILABLE' => 'Локальная защита недоступна. Данные сохранены.',
  'CONFLICT' ||
  'revision_changed' ||
  'revision_conflict' ||
  'RECONCILIATION_REQUIRED' =>
    'Данные изменились. Нужна свежая сверка перед применением.',
  'rate_limited' || 'storage_busy' => 'Сервис просит подождать перед повтором.',
  'AUTH_REQUIRED' ||
  'unauthenticated' ||
  'token_expired' => 'Для синхронизации нужен повторный вход.',
  'device_revoked' => 'Доступ устройства отозван. Локальные данные сохранены.',
  'vault_reset' => 'Хранилище сброшено. Подключите новое хранилище, сохранив локальные данные.',
  'CONSENT_CANCELLED' => 'Выбор отменён. Обе версии сохранены.',
  _ => 'Синхронизация не завершена. Сохранённые данные доступны локально.',
};
String _lastSuccess(int? value) {
  if (value == null) return 'Успешной синхронизации ещё не было';
  try {
    final d = DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
  } catch (_) {
    return 'Время недоступно';
  }
}

String _bytes(int? value) {
  if (value == null) return 'Будет известен после подготовки изменений';
  if (value < 1024) return '$value Б';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} КиБ';
  if (value < 1024 * 1024 * 1024)
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} МиБ';
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} ГиБ';
}

String _counts(SyncMergeCounts c) =>
    'Серверов: ${c.profiles}; карточек ПО: ${c.cards}';
String _delta(SyncMergeChanges c) =>
    'Добавится: ${_counts(c.added)}. Изменится: ${_counts(c.changed)}. Удалится: ${_counts(c.removed)}.';
String _conflictReason(SyncMergeConflictKind kind) => switch (kind) {
  SyncMergeConflictKind.firstDifferentId =>
    'Разные версии одной записи при подключении',
  SyncMergeConflictKind.concurrentCreate => 'Одна запись создана по-разному',
  SyncMergeConflictKind.editEdit => 'Запись изменена с обеих сторон',
  SyncMergeConflictKind.deleteEdit =>
    'Запись удалена с одной стороны и изменена с другой',
  SyncMergeConflictKind.missingProfile => 'Карточка без связанного сервера',
  SyncMergeConflictKind.duplicateCredential =>
    'Повторная связь с учётными данными',
  SyncMergeConflictKind.duplicateReference => 'Повторная связь с объектом',
  SyncMergeConflictKind.limits => 'Объединённый набор превышает лимит',
};

/// C07/C10/C11/C18/C24/C25 functional status and whole-set confirmation.
/// It consumes only the owner's vetted projection and never reads domain records.
class SyncStatusView extends StatefulWidget {
  const SyncStatusView({super.key, required this.owner});
  final SyncCycleActions owner;
  @override
  State<SyncStatusView> createState() => _SyncStatusViewState();
}

class _SyncStatusViewState extends State<SyncStatusView> {
  StreamSubscription<SyncCycleView>? _subscription;
  SyncMergePreview? _preview;
  SyncMergeChoice? _choice;
  bool _confirmed = false, _busy = false, _stale = false;
  int _generation = 0, _visibleConflicts = 20;
  String? _error;
  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _generation++;
    _busy = false;
    _error = null;
    _syncPreview();
    final owner = widget.owner;
    _subscription = owner.changes.listen((_) {
      if (!mounted || owner != widget.owner) return;
      setState(() {
        _syncPreview();
        _error = null;
      });
    });
  }

  void _syncPreview() {
    final preview = widget.owner.view.preview;
    if (identical(_preview, preview)) return;
    _preview = preview;
    _confirmed = false;
    _stale = false;
    _visibleConflicts = 20;
    _choice = preview?.merged != null ? SyncMergeChoice.automatic : null;
  }

  @override
  void didUpdateWidget(SyncStatusView old) {
    super.didUpdateWidget(old);
    if (old.owner != widget.owner) {
      unawaited(_subscription?.cancel());
      _preview = null;
      _bind();
    }
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _invoke(Future<void> Function(SyncCycleActions) action) async {
    if (_busy) return;
    final owner = widget.owner, generation = _generation, preview = _preview;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(owner);
    } catch (error) {
      if (mounted &&
          owner == widget.owner &&
          generation == _generation &&
          identical(preview, owner.view.preview))
        setState(() {
          _confirmed = false;
          _stale =
              error is OperationFailure && error.code == FailureCode.conflict;
          _error = _stale ? 'План устарел. Обновите его и подтвердите заново.' : 'Не удалось выполнить действие. Проверьте состояние синхронизации и повторите попытку.';
        });
    } finally {
      if (mounted && owner == widget.owner && generation == _generation)
        setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final preview = _preview, choice = _choice;
    if (_stale ||
        !_confirmed ||
        preview == null ||
        choice == null ||
        !identical(preview, widget.owner.view.preview))
      return;
    await _invoke((owner) => owner.confirm(preview, choice));
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.owner.view;
    final message = switch (view.phase) {
      SyncCyclePhase.paused => 'Синхронизация приостановлена.',
      SyncCyclePhase.waitingForKey =>
        'Для синхронизации нужно разблокировать хранилище.',
      SyncCyclePhase.checking => 'Сверяем данные между устройством и сервисом…',
      SyncCyclePhase.consent => 'Нужно согласие на выбранный набор данных.',
      SyncCyclePhase.conflict =>
        'Обнаружен конфликт. Выберите целый согласованный набор.',
      SyncCyclePhase.publishing => 'Передаём зашифрованные изменения…',
      SyncCyclePhase.synced => 'Данные подтверждены устройством и сервисом.',
      SyncCyclePhase.offlinePending =>
        'Есть ожидающие изменения или нужна повторная сверка.',
      SyncCyclePhase.error => 'Синхронизация требует внимания.',
    };
    final actionable =
        !_busy &&
        !{
          SyncCyclePhase.paused,
          SyncCyclePhase.waitingForKey,
          SyncCyclePhase.checking,
          SyncCyclePhase.publishing,
        }.contains(view.phase);
    final chooseEnabled = actionable && !_stale;
    final preview = _preview;
    final target = preview == null
        ? null
        : switch (_choice) {
            SyncMergeChoice.automatic => preview.merged,
            SyncMergeChoice.local => preview.local,
            SyncMergeChoice.server => preview.server,
            null => null,
          };
    final changes = preview == null
        ? null
        : switch (_choice) {
            SyncMergeChoice.automatic => preview.automaticChanges,
            SyncMergeChoice.server => preview.serverChanges,
            _ => null,
          };
    final legacy = target?.legacyMetadataOnlyKeys ?? 0;
    return DeckFormSection(
      title: 'Состояние синхронизации',
      children: [
        DeckStatus(
          label: message,
          tone: view.phase == SyncCyclePhase.synced
              ? DeckTone.success
              : {
                  SyncCyclePhase.error,
                  SyncCyclePhase.conflict,
                }.contains(view.phase)
              ? DeckTone.warning
              : DeckTone.neutral,
        ),
        DeckKeyValue(
          label: 'Локальные правки без подтверждения',
          value: '${view.pendingChanges}',
        ),
        DeckKeyValue(
          label: 'Размер подготовленного зашифрованного набора',
          value: _bytes(view.pendingBytes),
        ),
        DeckKeyValue(
          label: 'Последний успех',
          value: _lastSuccess(view.lastSuccessUtc),
        ),
        if (view.errorCode != null)
          DeckNotice(
            message: _cycleError(view.errorCode),
            tone: view.phase == SyncCyclePhase.error
                ? DeckTone.error
                : DeckTone.warning,
          ),
        if (view.retryAfterSeconds != null)
          Text(
            'Следующий повтор не раньше чем через ${view.retryAfterSeconds} с.',
          ),
        if (_error != null) DeckNotice(message: _error!, tone: DeckTone.error),
        DeckButton(
          key: const ValueKey('sync-retry'),
          onPressed: actionable
              ? () => _invoke((owner) => owner.retry())
              : null,
          pending: _busy,
          child: Text(
            preview == null ? 'Повторить синхронизацию' : 'Обновить план',
          ),
        ),
        if (preview != null)
          DeckPlanSummary.content(
            children: [
              DeckKeyValue(
                label: 'На этом устройстве',
                value: _counts(preview.local),
              ),
              DeckKeyValue(label: 'В сервисе', value: _counts(preview.server)),
              if (preview.baseUnavailable)
                const DeckNotice(
                  message: 'Исходная общая версия недоступна. Проверьте новый состав данных целиком перед согласованием.',
                  tone: DeckTone.warning,
                ),
              if (preview.conflicts.isNotEmpty) ...[
                Text('Причин конфликта: ${preview.conflicts.length}'),
                for (final conflict in preview.conflicts.take(
                  _visibleConflicts,
                ))
                  DeckListItem(
                    title: _conflictReason(conflict.reason),
                    description: conflict.id == null
                        ? null
                        : '${conflict.kind == 'software' ? 'Карточка ПО' : 'Сервер'}: ${conflict.id}',
                  ),
                if (_visibleConflicts < preview.conflicts.length)
                  DeckLoadMore(
                    hasMore: true,
                    onLoad: () => setState(() => _visibleConflicts += 20),
                  ),
              ],
              DropdownButtonFormField<SyncMergeChoice>(
                key: ObjectKey(preview),
                initialValue: _choice,
                decoration: const InputDecoration(
                  labelText: 'Какой набор использовать',
                ),
                items: [
                  if (preview.merged != null)
                    const DropdownMenuItem(
                      value: SyncMergeChoice.automatic,
                      child: Text('Объединить совместимые изменения'),
                    ),
                  const DropdownMenuItem(
                    value: SyncMergeChoice.local,
                    child: Text('Использовать локальный набор'),
                  ),
                  const DropdownMenuItem(
                    value: SyncMergeChoice.server,
                    child: Text('Использовать набор сервиса'),
                  ),
                ],
                onChanged: chooseEnabled
                    ? (value) => setState(() {
                        _choice = value;
                        _confirmed = false;
                      })
                    : null,
              ),
              if (_choice == SyncMergeChoice.local)
                DeckNotice(
                  message:
                      'Набор сервиса будет заменён локальным целиком. Не войдёт из сервиса: ${_counts(preview.serverChanges.added)}. Локальные данные останутся.',
                  tone: DeckTone.warning,
                ),
              if (_choice == SyncMergeChoice.server)
                const DeckNotice(
                  message: 'Локальный набор будет заменён набором сервиса целиком. Локальные записи, которых нет в сервисе, будут удалены.',
                  tone: DeckTone.warning,
                ),
              if (changes != null)
                DeckKeyValue(
                  label: 'Изменения на устройстве',
                  value: _delta(changes),
                ),
              if (target != null)
                DeckDiff(
                  entries: [
                    DeckDifference(
                      label: 'Серверов в локальном наборе',
                      before: '${preview.local.profiles}',
                      after: '${target.profiles}',
                      change:
                          changes != null &&
                              changes.added.profiles +
                                      changes.changed.profiles +
                                      changes.removed.profiles >
                                  0
                          ? DeckChange.changed
                          : DeckChange.unchanged,
                    ),
                    DeckDifference(
                      label: 'Карточек ПО в локальном наборе',
                      before: '${preview.local.cards}',
                      after: '${target.cards}',
                      change:
                          changes != null &&
                              changes.added.cards +
                                      changes.changed.cards +
                                      changes.removed.cards >
                                  0
                          ? DeckChange.changed
                          : DeckChange.unchanged,
                    ),
                  ],
                ),
              if (legacy > 0)
                DeckNotice(
                  message:
                      'Ключей со старым зашифрованным форматом: $legacy. При переносе проверена только открытая метаинформация; окончательная проверка будет при локальном вводе passphrase.',
                  tone: DeckTone.warning,
                ),
              const Text(
                'Значения паролей и приватных ключей не показываются. Доверие к SSH-ключам проверяется отдельно на каждом устройстве.',
              ),
              CheckboxListTile(
                key: const ValueKey('sync-merge-consent'),
                value: _confirmed,
                onChanged: chooseEnabled && _choice != null
                    ? (value) => setState(() => _confirmed = value ?? false)
                    : null,
                title: const Text(
                  'Я проверил план и согласен применить выбранный набор',
                ),
              ),
              DeckActions(
                children: [
                  DeckButton(
                    key: const ValueKey('sync-merge-confirm'),
                    kind: DeckButtonKind.primary,
                    onPressed: chooseEnabled && _confirmed && _choice != null
                        ? _submit
                        : null,
                    pending: _busy,
                    child: const Text('Применить выбранный набор'),
                  ),
                  DeckButton(
                    key: const ValueKey('sync-merge-cancel'),
                    onPressed: actionable
                        ? () {
                            widget.owner.cancelPreview();
                            setState(() {
                              _confirmed = false;
                              _error = null;
                            });
                          }
                        : null,
                    child: const Text('Отменить выбор'),
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }
}
