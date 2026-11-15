import 'package:flutter/material.dart';

import '../console/console_settings.dart';
import '../console/console_settings_view.dart';
import '../mcp/settings_controller.dart';
import '../mcp/settings_view.dart';
import '../ui/deck_components.dart';
import '../updates/update_owner.dart';
import '../updates/update_view.dart';
import '../sync/sync_runtime.dart';
import '../sync/account_view.dart';
import '../sync/sync_owner.dart';

/// Content inside the runtime-owned settings route and its nested Navigator.
class ApplicationSettingsView extends StatefulWidget {
  const ApplicationSettingsView({
    super.key,
    this.updates,
    this.sync,
    this.platform = 'windows',
    this.mcp,
    this.onUpdateRestart,
    this.terminalSettings,
    this.newTerminalProfileId,
  }) : assert((terminalSettings == null) == (newTerminalProfileId == null));
  final UpdateOwner? updates;
  final SyncRuntime? sync;
  final String platform;
  final Future<bool> Function(String version)? onUpdateRestart;
  final McpSettingsController? mcp;
  final ConsoleSettingsOwner? terminalSettings;
  final String Function()? newTerminalProfileId;
  @override
  State<ApplicationSettingsView> createState() =>
      _ApplicationSettingsViewState();
}

class _ApplicationSettingsViewState extends State<ApplicationSettingsView> {
  int _selected = 0;
  @override
  Widget build(BuildContext context) {
    final sections = <(String, IconData, Widget)>[
      if (widget.updates != null)
        (
          'Обновления',
          Icons.system_update_alt,
          UpdateView(owner: widget.updates!, onRestart: widget.onUpdateRestart),
        ),
      if (widget.mcp != null)
        ('MCP', Icons.hub_outlined, McpSettingsView(controller: widget.mcp!)),
      if (widget.terminalSettings != null)
        (
          'Терминал',
          Icons.terminal,
          SingleChildScrollView(
            child: ConsoleSettingsView(
              owner: widget.terminalSettings!,
              newId: widget.newTerminalProfileId!,
            ),
          ),
        ),
      if (widget.sync != null)
        (
          'Аккаунт и синхронизация',
          Icons.sync,
          _SyncSettings(runtime: widget.sync!, platform: widget.platform),
        ),
    ];
    if (sections.isEmpty)
      return const DeckNotice(
        title: 'Настройки недоступны',
        message: 'Нет доступных разделов.',
      );
    final labels = [for (final section in sections) section.$1];
    final icons = [for (final section in sections) section.$2];
    final selected = _selected < labels.length ? _selected : 0;
    final content = sections[selected].$3;
    return Column(
      children: [
        if (labels.length > 1)
          DeckTabs(
            labels: labels,
            icons: icons,
            selected: selected,
            onSelected: (value) => setState(() => _selected = value),
          ),
        Expanded(child: content),
      ],
    );
  }
}

/// Keep account ownership mounted while the browser pauses and sync recalibrates.
final class _SyncSettings extends StatefulWidget {
  const _SyncSettings({required this.runtime, required this.platform});
  final SyncRuntime runtime;
  final String platform;
  @override
  State<_SyncSettings> createState() => _SyncSettingsState();
}

final class _SyncSettingsState extends State<_SyncSettings> {
  bool _admitted = false;
  @override
  void didUpdateWidget(_SyncSettings old) {
    super.didUpdateWidget(old);
    if (old.runtime != widget.runtime) _admitted = false;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.runtime,
    builder: (context, _) {
      final runtime = widget.runtime;
      if (runtime.foregroundError == null &&
          runtime.owner.view.phase != SyncAuthPhase.paused)
        _admitted = true;
      final notice = DeckNotice(
        title: 'Синхронизация приостановлена',
        message: 'Повторите подготовку синхронизации. Локальные данные и SSH доступны.',
        tone: runtime.foregroundError == null
            ? DeckTone.neutral
            : DeckTone.error,
        actions: [
          DeckButton(
            onPressed: runtime.retryForeground,
            child: const Text('Повторить синхронизацию'),
          ),
        ],
      );
      if (!_admitted) return notice;
      return Column(
        children: [
          if (runtime.foregroundError != null)
            notice
          else
            const SizedBox.shrink(),
          Expanded(
            child: SingleChildScrollView(
              child: SyncAccountView(
                key: ValueKey(runtime.owner),
                owner: runtime.owner,
                platform: widget.platform,
                defaultDeviceName: widget.platform == 'android'
                    ? 'Android'
                    : 'Windows',
              ),
            ),
          ),
        ],
      );
    },
  );
}
