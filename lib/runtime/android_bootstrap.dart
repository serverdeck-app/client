import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../theme/brand_theme.dart';
import '../ui/deck_components.dart';
import 'android_platform.dart';
import 'android_runtime.dart';
import 'platform_ports.dart';
import 'runtime_coordinator.dart';

/// A first frame with retry exists even when native initialization fails.
final class AndroidBootstrap extends StatefulWidget {
  const AndroidBootstrap({super.key});
  @override
  State<AndroidBootstrap> createState() => _AndroidBootstrapState();
}

final class _AndroidBootstrapState extends State<AndroidBootstrap> {
  final _platform = AndroidPlatform();
  AndroidApplicationWorkspace? _workspace;
  RuntimeCoordinator? _runtime;
  bool _busy = false, _failed = false;
  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (_busy || _runtime != null) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final context = await _platform.initialize();
      if (!mounted) {
        await _platform.dispose();
        return;
      }
      final workspace = AndroidApplicationWorkspace(_platform);
      final runtime = RuntimeCoordinator(
        platform: AndroidRuntimePlatform(_platform),
        store: workspace,
        epoch: context.epoch,
        capabilities: PlatformCapabilities.android,
      );
      workspace.isRunning = () => runtime.acceptsOperations;
      runtime.register(workspace);
      setState(() {
        _workspace = workspace;
        _runtime = runtime;
      });
      unawaited(runtime.start());
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime, workspace = _workspace;
    if (runtime != null && workspace != null) {
      return ServerDeckApp(
        runtime: runtime,
        store: workspace,
        features: () => workspace.features,
        capabilities: PlatformCapabilities.android,
      );
    }
    return MaterialApp(
      theme: BrandTheme.dark,
      home: Scaffold(
        body: Center(
          child: DeckNotice(
            title: _failed ? 'Данные недоступны' : 'Открываем данные',
            message: _failed
                ? 'Не удалось подготовить хранилище. Существующие данные сохранены.'
                : 'Подождите',
            tone: _failed ? DeckTone.error : DeckTone.running,
            actions: [
              if (_failed)
                DeckButton(
                  onPressed: _busy ? null : _initialize,
                  child: const Text('Повторить'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    final runtime = _runtime;
    if (runtime != null) {
      unawaited(runtime.requestExit());
    } else if (!_busy) {
      unawaited(_platform.dispose());
    }
    super.dispose();
  }
}
