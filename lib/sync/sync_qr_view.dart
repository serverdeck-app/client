import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../ui/deck_components.dart';
import 'sync_key_transfer.dart';
import 'sync_qr_camera.dart';
import 'sync_recovery.dart';

/// C10/11/12/13/14/16/17/18/24. Secret exists only in this explicit dialog.
class SyncQrDialog extends StatefulWidget {
  const SyncQrDialog({
    super.key,
    required this.owner,
    this.transfer,
    this.capture,
    this.createCameraDriver,
    this.canDisplay,
    required this.onManual,
  });
  final SyncVaultOwner owner;
  final SyncKeyTransfer? transfer;
  final SyncQrImportCapture? capture;
  final SyncQrCameraDriver Function()? createCameraDriver;
  final bool Function()? canDisplay;
  final VoidCallback onManual;
  @override
  State<SyncQrDialog> createState() => _SyncQrDialogState();
}

class _SyncQrDialogState extends State<SyncQrDialog>
    with WidgetsBindingObserver {
  StreamSubscription<SyncVaultView>? _subscription;
  late SyncQrImportCapture? _capture;
  late final int _generation;
  SyncKeyTransfer? _candidate;
  Timer? _timer;
  bool _closed = false, _busy = false;
  String? _error;
  bool get _display => widget.transfer != null;
  @override
  void initState() {
    super.initState();
    _capture = widget.capture;
    _generation = widget.owner.actionGeneration;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer(Duration(seconds: _display ? 60 : 120), _close);
    _subscription = widget.owner.changes.listen((_) {
      if (!_current()) _close();
    });
  }

  bool _current() {
    final owner = widget.owner;
    if (_display)
      return (widget.canDisplay?.call() ?? true) &&
          owner.actionGeneration == _generation &&
          owner.view.phase == SyncVaultPhase.ready;
    if (_busy)
      return owner.actionGeneration == _capture!.generation + 1 &&
          {
            SyncVaultPhase.unlocking,
            SyncVaultPhase.error,
          }.contains(owner.view.phase);
    return owner.isQrImportCurrent(_capture!);
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    _candidate?.dispose();
    _candidate = null;
    widget.transfer?.dispose();
    if (_busy && widget.owner.view.phase == SyncVaultPhase.unlocking)
      widget.owner.lock();
    setState(() {});
    final route = ModalRoute.of(context);
    if (route?.isCurrent == true) Navigator.of(context).pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The camera adapter handles the bounded permission-related inactive state.
    if (state == AppLifecycleState.resumed) return;
    if (!_display && state == AppLifecycleState.inactive && _candidate == null)
      return;
    _close();
  }

  void _detected(String value) {
    if (_closed || _busy || _candidate != null || _error != null || !_current())
      return;
    try {
      final transfer = SyncKeyTransfer.parse(value, _capture!.identity);
      if (!_current()) {
        transfer.dispose();
        return;
      }
      setState(() => _candidate = transfer);
    } catch (_) {
      setState(
        () => _error = 'QR не подходит. Проверьте сервис, аккаунт и хранилище на обоих устройствах.',
      );
    }
  }

  Future<void> _unlock() async {
    final candidate = _candidate;
    if (_closed || _busy || candidate == null || !_current()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.owner.unlockQr(candidate, _capture!);
      if (mounted) _close();
    } catch (_) {
      if (mounted && !_closed) {
        try {
          _capture = widget.owner.captureQrImport();
        } catch (_) {
          _close();
          return;
        }
        setState(() {
          _candidate?.dispose();
          _candidate = null;
          _error =
              'Ключ не подошёл или хранилище изменилось. Данные не заменены.';
        });
      }
    } finally {
      if (mounted && !_closed) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    _candidate?.dispose();
    widget.transfer?.dispose();
    if (_busy && widget.owner.view.phase == SyncVaultPhase.unlocking)
      widget.owner.lock();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_closed) return const SizedBox.shrink();
    if (_display && !_current()) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _close());
      return const SizedBox.shrink();
    }
    return DeckDialogLayout(
      title: _display
          ? 'Перенос ключа на Android'
          : 'Сканировать ключ хранилища',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_display) ...[
            const Text(
              'Этот QR содержит ключ расшифровки. Не фотографируйте и не отправляйте его другим. Он скроется через 60 секунд; сохранённая копия останется секретом.',
            ),
            ExcludeSemantics(
              child: QrImageView(
                data: widget.transfer!.payload,
                size: 300,
                backgroundColor: Colors.white,
                errorStateBuilder: (_, _) => const Text(
                  'Не удалось показать QR. Используйте код восстановления.',
                ),
              ),
            ),
          ] else ...[
            const Text(
              'Войдите в тот же аккаунт VK. Наведите камеру на QR в Windows. Ключ не передаётся серверу.',
            ),
            if (_candidate == null && _error == null)
              SyncQrCamera(
                createDriver: widget.createCameraDriver,
                onCode: _detected,
                onRetired: _close,
              ),
            if (_candidate != null)
              const Text(
                'QR проверен для этого аккаунта и хранилища. Подтвердите разблокировку.',
              ),
            if (_error != null)
              DeckNotice(message: _error!, tone: DeckTone.error),
          ],
        ],
      ),
      actions: [
        DeckButton(
          onPressed: _close,
          child: Text(_display ? 'Скрыть QR' : 'Отмена'),
        ),
        if (!_display) ...[
          DeckButton(
            onPressed: _busy
                ? null
                : () {
                    widget.onManual();
                    _close();
                  },
            child: const Text('Ввести вручную'),
          ),
          if (_error != null)
            DeckButton(
              onPressed: () => setState(() => _error = null),
              child: const Text('Сканировать снова'),
            ),
          if (_candidate != null)
            DeckButton(
              kind: DeckButtonKind.primary,
              pending: _busy,
              onPressed: _busy ? null : _unlock,
              child: const Text('Разблокировать'),
            ),
        ],
      ],
    );
  }
}
