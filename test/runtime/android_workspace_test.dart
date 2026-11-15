import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/runtime/android_workspace.dart';
import 'package:serverdeck/runtime/platform_ports.dart';
import 'package:serverdeck/storage/store_manifest.dart';
import 'package:serverdeck/storage/workspace_store.dart';

import '../fixtures/fake_store_backend.dart';

class _Ports implements PlatformStoragePort, PlatformSecretPort {
  _Ports(this.root);
  final Directory root;
  final publications = <String>[];
  final purposes = <String>[];
  Completer<void>? preparing;
  bool wrongLocation = false, failProtection = false, failPublication = false;
  @override
  Future<PlatformStorageLocation> prepareStorage() async {
    await preparing?.future;
    return wrongLocation
        ? FileLibraryStorageLocation(dataRoot: root.path, libraryPath: 'no-dll')
        : BundledLibraryStorageLocation(dataRoot: root.path);
  }

  @override
  Future<Uint8List> protect(Uint8List bytes, String purpose) async {
    purposes.add(purpose);
    expect(bytes.length, 32);
    if (failProtection) throw StateError('synthetic protection failure');
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<Uint8List> unprotect(Uint8List bytes, String purpose) =>
      throw StateError('Unexpected unprotect');
  @override
  Future<int> availableStorageBytes() async => 1024 * 1024;
  @override
  Future<void> flushAtomic(String path, Uint8List bytes) async {
    publications.add(path);
    if (path.startsWith('data/flush/')) return;
    final id = path.substring('data/publish/'.length);
    await Directory('${root.path}/data/stores').create(recursive: true);
    final staging = Directory('${root.path}/data/staging-$id');
    if (await staging.exists()) {
      await staging.rename('${root.path}/data/stores/$id');
    }
    if (failPublication) {
      failPublication = false;
      throw const StoreFailure('STORAGE_IO');
    }
    await File('${root.path}/data/CURRENT.json').writeAsBytes(bytes);
  }
}

void main() {
  for (final abi in [Abi.androidArm64, Abi.androidX64]) {
    test('packaged $abi uses default library and never downloads', () async {
      var calls = 0;
      final backend = IsarStoreBackend(
        currentAbi: () => abi,
        initializeCore: (libraries, download) async {
          calls++;
          expect(libraries, isEmpty);
          expect(download, isFalse);
        },
      );
      await backend.initialize(null);
      expect(calls, 1);
    });
  }
  test(
    'reject unsupported packaged ABI and mismatched file ABI before loader',
    () async {
      var calls = 0;
      for (final abi in [Abi.androidArm, Abi.windowsX64, Abi.linuxX64]) {
        final backend = IsarStoreBackend(
          currentAbi: () => abi,
          initializeCore: (_, _) async {
            calls++;
          },
        );
        expect(() => backend.initialize(null), throwsA(isA<StoreFailure>()));
      }
      final android = IsarStoreBackend(
        currentAbi: () => Abi.androidArm64,
        initializeCore: (_, _) async {
          calls++;
        },
      );
      expect(
        () => android.initialize('synthetic.dll'),
        throwsA(isA<StoreFailure>()),
      );
      expect(calls, 0);
    },
  );
  test('Windows retains explicit library mapping without download', () async {
    final backend = IsarStoreBackend(
      currentAbi: () => Abi.windowsX64,
      initializeCore: (libraries, download) async {
        expect(libraries, {Abi.windowsX64: 'synthetic.dll'});
        expect(download, isFalse);
      },
    );
    await backend.initialize('synthetic.dll');
  });

  late Directory root;
  late _Ports ports;
  late FakeStoreBackend backend;
  late AndroidWorkspace workspace;
  var disposed = 0;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('android-workspace-unit-');
    ports = _Ports(root);
    backend = FakeStoreBackend();
    disposed = 0;
    workspace = AndroidWorkspace(
      storage: ports,
      secrets: ports,
      backend: backend,
      disposePlatform: () async {
        expect(backend.databases.values.every((db) => db.closes > 0), isTrue);
        disposed++;
      },
    );
  });
  tearDown(() async {
    await workspace.close();
    await root.delete(recursive: true);
  });
  test('fresh bundled workspace publishes common CURRENT; reopen preserves identity', () async {
    await Future.wait([workspace.open(), workspace.open()]);
    expect(backend.initialized, [null]);
    expect(workspace.store.isOpen, isTrue);
    expect(ports.purposes, ['receipt-hmac.v1']);
    final current = File('${root.path}/data/CURRENT.json');
    final bytes = await current.readAsBytes();
    final manifest = StoreManifest.decode(bytes);
    expect(backend.openedPaths.last, endsWith(manifest.relativeDirectory));
    final calls = ports.publications.length;
    await workspace.store.close();
    await workspace.open();
    expect(await current.readAsBytes(), bytes);
    expect(ports.publications.length, calls);
    expect(ports.purposes.length, 1);
    await workspace.close();
    expect(disposed, 1);
    await workspace.close();
    expect(disposed, 1);
  });
  test(
    'missing CURRENT with orphan fails before loader and preserves bytes',
    () async {
      final saved = File('${root.path}/data/stores/orphan/serverdeck.isar');
      await saved.parent.create(recursive: true);
      await saved.writeAsString('saved-data');
      await expectLater(workspace.open(), throwsA(isA<StoreFailure>()));
      expect(backend.initialized, isEmpty);
      expect(await saved.readAsString(), 'saved-data');
      expect(ports.publications, isEmpty);
    },
  );
  test(
    'publication failure retries same UUID without another receipt key',
    () async {
      ports.failPublication = true;
      await expectLater(workspace.open(), throwsA(isA<StoreFailure>()));
      await workspace.open();
      final publish = ports.publications.where(
        (p) => p.startsWith('data/publish/'),
      );
      expect(publish.length, 2);
      expect(publish.toSet().length, 1);
      expect(ports.purposes.length, 1);
      expect(workspace.store.isOpen, isTrue);
    },
  );
  test(
    'failed DB close retains lease and retry closes before native dispose',
    () async {
      await workspace.open();
      backend.databases.values.single.failingCloses = 1;
      await expectLater(workspace.close(), throwsA(isA<StoreFailure>()));
      expect(disposed, 0);
      expect(workspace.store.isOpen, isTrue);
      await workspace.close();
      expect(disposed, 1);
      expect(workspace.store.isOpen, isFalse);
    },
  );
  test('stop during prepare never initializes or reopens storage', () async {
    ports.preparing = Completer<void>();
    final opening = workspace.open();
    final expected = expectLater(opening, throwsA(isA<StoreFailure>()));
    workspace.stopAdmission();
    ports.preparing!.complete();
    await expected;
    expect(backend.initialized, isEmpty);
    await expectLater(workspace.open(), throwsA(isA<StoreFailure>()));
  });
  test('mismatched location and protection failure never publish', () async {
    ports.wrongLocation = true;
    await expectLater(workspace.open(), throwsA(isA<StoreFailure>()));
    expect(backend.initialized, isEmpty);
    ports.wrongLocation = false;
    ports.failProtection = true;
    await expectLater(workspace.open(), throwsStateError);
    expect(ports.publications, isEmpty);
    expect(workspace.store.isOpen, isFalse);
  });
}
