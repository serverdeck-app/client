import 'dart:async';
import 'dart:typed_data';

import '../domain/models.dart';
import 'sync_http.dart';
import 'sync_json.dart';
import 'sync_models.dart';
import 'sync_wire.dart';

final class SyncTransportCancelled implements Exception {
  const SyncTransportCancelled();
  @override
  String toString() => 'SYNC_CANCELLED';
}

final class SyncCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  bool get cancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void Function() listen(void Function() listener) {
    if (_cancelled)
      listener();
    else
      _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

const _remoteStatuses = <String, int>{
  'invalid_request': 400,
  'invalid_blob': 400,
  'authorization_pending': 400,
  'access_denied': 400,
  'expired_token': 400,
  'slow_down': 400,
  'unauthenticated': 401,
  'token_expired': 401,
  'device_revoked': 403,
  'csrf_failed': 403,
  'reauthentication_required': 403,
  'refresh_reused': 403,
  'browser_action_required': 403,
  'not_found': 404,
  'revision_conflict': 409,
  'revision_changed': 409,
  'vault_reset': 409,
  'idempotency_conflict': 409,
  'device_limit': 409,
  'upload_expired': 410,
  'length_required': 411,
  'payload_too_large': 413,
  'unsupported_media_type': 415,
  'unsupported_content_version': 422,
  'invalid_manifest': 422,
  'rate_limited': 429,
  'storage_busy': 503,
  'storage_unavailable': 503,
  'resource_exhausted': 503,
  'mail_unavailable': 503,
  'clock_untrusted': 503,
};

int? _retrySeconds(String? header, {required bool mandatory}) {
  if (header == null) {
    if (mandatory) throw syncInvalidWire;
    return null;
  }
  if (!RegExp(r'^[0-9]{1,16}$').hasMatch(header)) throw syncInvalidWire;
  return SyncWire.integer(int.tryParse(header), min: mandatory ? 5 : 0);
}

final class SyncRemoteFailure implements Exception {
  SyncRemoteFailure._(
    this.status,
    this.code,
    this.requestId,
    this.retryAfterSeconds,
    this.vaultId,
    this.revision,
  );
  final int status;
  final String code, requestId;
  final int? retryAfterSeconds, revision;
  final String? vaultId;
  @override
  String toString() => 'SD_SYNC_$code';
  factory SyncRemoteFailure.parse(
    int status,
    Object? value,
    String? retryHeader,
  ) {
    if (value is! Map<String, Object?>) throw syncInvalidWire;
    final code = SyncWire.text(value['error'], max: 40);
    if (_remoteStatuses[code] != status) throw syncInvalidWire;
    final fields = {
      'error',
      'request_id',
      if (value.containsKey('retry_after_seconds')) 'retry_after_seconds',
      if (code == 'revision_conflict') ...['vault_id', 'revision'],
    };
    final map = SyncWire.exact(value, fields);
    int? retry = _retrySeconds(
      retryHeader,
      mandatory: status == 429 || status == 503,
    );
    if (map.containsKey('retry_after_seconds')) {
      final bodyRetry = SyncWire.integer(map['retry_after_seconds'], min: 5);
      retry = retry == null || bodyRetry > retry ? bodyRetry : retry;
    }
    if ((status == 429 || status == 503) && retryHeader == null)
      throw syncInvalidWire;
    return SyncRemoteFailure._(
      status,
      code,
      SyncWire.uuid(map['request_id']),
      retry,
      code == 'revision_conflict' ? SyncWire.uuid(map['vault_id']) : null,
      code == 'revision_conflict' ? SyncWire.integer(map['revision']) : null,
    );
  }
}

enum SyncDeviceStatus { active, revoked, vaultReset }

/// A fixed-origin, single-request consumer. No implicit retry or refresh: those
/// decisions belong to the generation-fenced owner. No domain/storage mutations.
final class SyncTransport {
  SyncTransport({
    required this.origin,
    required SyncHttpPort http,
    this.metadataTimeout = const Duration(seconds: 30),
    this.blobInactivityTimeout = const Duration(seconds: 60),
  }) : _http = http {
    if (metadataTimeout <= Duration.zero ||
        blobInactivityTimeout <= Duration.zero)
      throw syncInvalidWire;
  }
  final SyncServiceOrigin origin;
  final SyncHttpPort _http;
  final Duration metadataTimeout, blobInactivityTimeout;
  final _active = <SyncCancellation>{};
  bool _disposed = false;
  void dispose() {
    _disposed = true;
    for (final cancellation in List.of(_active)) {
      cancellation.cancel();
    }
  }

  void _bound(SyncBoundSecret secret, SyncSecretKind kind) {
    if (secret.origin.value != origin.value || secret.kind != kind)
      throw syncInvalidWire;
  }

  Future<SyncDeviceAuthorization> beginDevice({
    required String platform,
    required String name,
    SyncCancellation? cancel,
  }) async {
    if (!{'windows', 'android'}.contains(platform)) throw syncInvalidWire;
    return SyncDeviceAuthorization.parse(
      await _json(
        'POST',
        '/v1/device-authorizations',
        body: {
          'platform': platform,
          'device_name': SyncWire.deviceName(name.trim()),
        },
        statuses: {201},
        cancel: cancel,
      ),
      origin,
    );
  }

  Future<SyncNativeSession> pollDevice(
    SyncBoundSecret code, {
    SyncCancellation? cancel,
  }) async {
    _bound(code, SyncSecretKind.deviceCode);
    return SyncNativeSession.parse(
      await _json(
        'POST',
        '/v1/device-token',
        body: {'device_code': code.value},
        cancel: cancel,
      ),
      origin,
    );
  }

  Future<SyncSessionTokens> refresh(
    SyncBoundSecret token, {
    SyncCancellation? cancel,
  }) async {
    _bound(token, SyncSecretKind.refresh);
    return SyncSessionTokens.parse(
      await _json(
        'POST',
        '/v1/token/refresh',
        body: {'refresh_token': token.value},
        cancel: cancel,
      ),
      origin,
    );
  }

  Future<SyncDeviceStatus> status(
    SyncBoundSecret proof, {
    SyncCancellation? cancel,
  }) async {
    _bound(proof, SyncSecretKind.statusProof);
    final map = SyncWire.exact(
      await _json(
        'POST',
        '/v1/device-status',
        body: {'status_proof': proof.value},
        cancel: cancel,
      ),
      {'status'},
    );
    return switch (map['status']) {
      'active' => SyncDeviceStatus.active,
      'revoked' => SyncDeviceStatus.revoked,
      'vault_reset' => SyncDeviceStatus.vaultReset,
      _ => throw syncInvalidWire,
    };
  }

  Future<List<SyncRemoteDevice>> devices(
    SyncBoundSecret access, {
    SyncCancellation? cancel,
  }) async {
    final map = SyncWire.exact(
      await _json('GET', '/v1/devices', access: access, cancel: cancel),
      {'devices'},
    );
    if (map['devices'] is! List || (map['devices']! as List).length > 10)
      throw syncInvalidWire;
    final devices = (map['devices']! as List)
        .map(SyncRemoteDevice.parse)
        .toList(growable: false);
    if (devices.map((device) => device.id).toSet().length != devices.length)
      throw syncInvalidWire;
    return List.unmodifiable(devices);
  }

  Future<void> logout(SyncBoundSecret access, {SyncCancellation? cancel}) =>
      _empty('POST', '/v1/logout', access, cancel: cancel);
  Future<void> revokeSelf(
    SyncBoundSecret access,
    String deviceId, {
    SyncCancellation? cancel,
  }) => _empty(
    'POST',
    '/v1/devices/${SyncWire.uuid(deviceId)}/revoke',
    access,
    cancel: cancel,
  );
  Future<SyncHead> head(
    SyncBoundSecret access, {
    required String vaultId,
    SyncCancellation? cancel,
  }) async {
    SyncWire.uuid(vaultId);
    return SyncHead.parse(
      await _json(
        'GET',
        '/v1/vault/head',
        access: access,
        maxBytes: syncMaxRootBytes + 512,
        cancel: cancel,
      ),
      vaultId: vaultId,
    );
  }

  Future<SyncUploadDeclaration> declare(
    SyncBoundSecret access, {
    required String uploadId,
    required int expectedRevision,
    required SyncManifest manifest,
    SyncCancellation? cancel,
  }) async {
    SyncWire.uuid(uploadId);
    SyncWire.integer(expectedRevision, max: syncMaxInteger - 1);
    if (manifest.revision != expectedRevision + 1) throw syncInvalidWire;
    return SyncUploadDeclaration.parse(
      await _json(
        'POST',
        '/v1/vault/uploads',
        access: access,
        body: {
          'upload_id': uploadId,
          'expected_revision': expectedRevision,
          'manifest': manifest.toJson(),
        },
        statuses: {200, 201},
        maxBytes: syncMaxRootBytes + 512,
        cancel: cancel,
      ),
      uploadId,
      manifest,
    );
  }

  Future<void> upload(
    SyncBoundSecret access, {
    required String uploadId,
    required SyncBlobRef ref,
    required Uint8List ciphertext,
    SyncCancellation? cancel,
  }) async {
    SyncWire.uuid(uploadId);
    _bound(access, SyncSecretKind.access);
    if (ciphertext.length != ref.bytes) throw syncInvalidWire;
    final frozen = Uint8List.fromList(ciphertext);
    try {
      if (syncSha256(frozen) != ref.sha256) throw syncInvalidWire;
      await _request(
        'PUT',
        '/v1/vault/uploads/$uploadId/blobs/${ref.sha256}',
        body: frozen,
        access: access,
        success: {204},
        maxBytes: 0,
        binary: true,
        cancel: cancel,
      );
    } finally {
      frozen.fillRange(0, frozen.length, 0);
    }
  }

  Future<Uint8List> download(
    SyncBoundSecret access, {
    required SyncBlobRef ref,
    required int revision,
    SyncCancellation? cancel,
  }) async {
    SyncWire.integer(revision, min: 1);
    final bytes = await _request(
      'GET',
      '/v1/vault/blobs/${ref.sha256}',
      access: access,
      query: {'revision': '$revision'},
      success: {200},
      maxBytes: ref.bytes,
      binary: true,
      cancel: cancel,
    );
    if (bytes.length != ref.bytes || syncSha256(bytes) != ref.sha256) {
      bytes.fillRange(0, bytes.length, 0);
      throw syncInvalidWire;
    }
    return bytes;
  }

  Future<SyncCommitReceipt> commit(
    SyncBoundSecret access, {
    required String uploadId,
    required String commitId,
    required SyncManifest manifest,
    SyncCancellation? cancel,
  }) async {
    SyncWire.uuid(uploadId);
    SyncWire.uuid(commitId);
    return SyncCommitReceipt.parse(
      await _json(
        'POST',
        '/v1/vault/uploads/$uploadId/commit',
        access: access,
        body: {'commit_id': commitId},
        cancel: cancel,
      ),
      commitId,
      manifest,
    );
  }

  Future<void> cancelUpload(
    SyncBoundSecret access,
    String uploadId, {
    SyncCancellation? cancel,
  }) => _empty(
    'DELETE',
    '/v1/vault/uploads/${SyncWire.uuid(uploadId)}',
    access,
    cancel: cancel,
  );

  Future<void> _empty(
    String method,
    String path,
    SyncBoundSecret access, {
    SyncCancellation? cancel,
  }) async {
    final bytes = await _request(
      method,
      path,
      access: access,
      success: {204},
      maxBytes: 0,
      cancel: cancel,
    );
    bytes.fillRange(0, bytes.length, 0);
  }

  Future<Object?> _json(
    String method,
    String path, {
    Object? body,
    SyncBoundSecret? access,
    Set<int> statuses = const {200},
    int maxBytes = 16384,
    SyncCancellation? cancel,
  }) async {
    final encoded = body == null ? null : canonicalSyncJson(body);
    Uint8List? bytes;
    try {
      final requestLimit = path == '/v1/vault/uploads'
          ? syncMaxRootBytes + 512
          : 16384;
      if (encoded != null && encoded.length > requestLimit)
        throw syncInvalidWire;
      bytes = await _request(
        method,
        path,
        body: encoded,
        access: access,
        success: statuses,
        maxBytes: maxBytes,
        cancel: cancel,
      );
      return strictSyncJson(bytes, maxBytes: maxBytes);
    } finally {
      encoded?.fillRange(0, encoded.length, 0);
      bytes?.fillRange(0, bytes.length, 0);
    }
  }

  Future<Uint8List> _request(
    String method,
    String path, {
    Uint8List? body,
    SyncBoundSecret? access,
    Map<String, String>? query,
    required Set<int> success,
    required int maxBytes,
    bool binary = false,
    SyncCancellation? cancel,
  }) async {
    if (_disposed) throw const SyncTransportCancelled();
    if (access != null) _bound(access, SyncSecretKind.access);
    final operation = SyncCancellation();
    final stopRead = SyncCancellation();
    var finished = false;
    final failed = Completer<Uint8List>();
    Timer? timer;
    SyncHttpCall? call;
    final removeExternal = cancel?.listen(operation.cancel);
    _active.add(operation);
    final remove = operation.listen(() {
      if (!failed.isCompleted)
        failed.completeError(const SyncTransportCancelled());
      stopRead.cancel();
      call?.cancel();
    });
    void restartTimer() {
      if (finished || operation.cancelled || failed.isCompleted) return;
      timer?.cancel();
      timer = Timer(binary ? blobInactivityTimeout : metadataTimeout, () {
        if (!failed.isCompleted)
          failed.completeError(
            const OperationFailure(FailureCode.timeout, retryable: true),
          );
        stopRead.cancel();
        call?.cancel();
      });
    }

    Future<Uint8List> run() async {
      if (operation.cancelled) throw const SyncTransportCancelled();
      restartTimer();
      final headers = <String, String>{
        'accept': binary && method == 'GET'
            ? 'application/octet-stream'
            : 'application/json',
        'accept-encoding': 'identity',
        if (body != null)
          'content-type': binary
              ? 'application/octet-stream'
              : 'application/json',
        if (access != null) 'authorization': 'Bearer ${access.value}',
      };
      call = _http.send(
        SyncHttpRequest(method, origin.resolve(path, query), headers, body),
        onProgress: () {
          if (binary) restartTimer();
        },
      );
      final response = await call!.response;
      if (operation.cancelled || failed.isCompleted)
        throw const SyncTransportCancelled();
      if (binary) restartTimer();
      final ok = success.contains(response.status);
      final limit = ok ? maxBytes : 16384;
      final noBody = ok && response.status == 204;
      final contentType = _single(response, 'content-type');
      final encoding = _single(response, 'content-encoding');
      if (encoding != null && encoding.toLowerCase() != 'identity')
        throw syncInvalidWire;
      if (!noBody) {
        final expectedType = ok && binary && method == 'GET'
            ? 'application/octet-stream'
            : 'application/json';
        if (contentType == null || !_mediaType(contentType, expectedType))
          throw syncInvalidWire;
      }
      final declared = _single(response, 'content-length');
      final retryHeader = _single(response, 'retry-after');
      _retrySeconds(
        retryHeader,
        mandatory: response.status == 429 || response.status == 503,
      );
      int? length;
      if (declared != null) {
        if (!RegExp(r'^[0-9]{1,16}$').hasMatch(declared)) throw syncInvalidWire;
        length = int.tryParse(declared);
        if (length == null || length > limit) throw syncInvalidWire;
      }
      // Redirect/error responses are never followed and only bounded JSON errors
      // are decoded. A malicious redirect cannot put credentials on another URI.
      final bytes = await _read(
        response.body,
        limit,
        stop: stopRead,
        onProgress: () {
          if (binary) restartTimer();
        },
      );
      var retained = false;
      try {
        if (operation.cancelled || failed.isCompleted)
          throw const SyncTransportCancelled();
        if (length != null && length != bytes.length) throw syncInvalidWire;
        if (!ok)
          throw SyncRemoteFailure.parse(
            response.status,
            strictSyncJson(bytes, maxBytes: 16384),
            retryHeader,
          );
        retained = true;
        return bytes;
      } finally {
        if (!retained) bytes.fillRange(0, bytes.length, 0);
      }
    }

    try {
      return await Future.any([run(), failed.future]);
    } on OperationFailure {
      rethrow;
    } on SyncRemoteFailure {
      rethrow;
    } on SyncTransportCancelled {
      rethrow;
    } catch (_) {
      throw const OperationFailure(FailureCode.networkError, retryable: true);
    } finally {
      finished = true;
      timer?.cancel();
      stopRead.cancel();
      remove();
      removeExternal?.call();
      _active.remove(operation);
      call?.cancel();
    }
  }
}

String? _single(SyncHttpResponse response, String name) {
  final values = response.headers[name];
  if (values == null) return null;
  if (values.length != 1) throw syncInvalidWire;
  return values.single;
}

bool _mediaType(String value, String expected) {
  final parts = value
      .toLowerCase()
      .split(';')
      .map((part) => part.trim())
      .toList();
  return parts.first == expected &&
      (parts.length == 1 ||
          expected == 'application/json' &&
              parts.length == 2 &&
              parts[1] == 'charset=utf-8');
}

Future<Uint8List> _read(
  Stream<List<int>> stream,
  int limit, {
  required void Function() onProgress,
  required SyncCancellation stop,
}) async {
  final buffer = Uint8List(limit);
  final done = Completer<void>();
  StreamSubscription<List<int>>? subscription;
  var size = 0;
  var retained = false;
  final remove = stop.listen(() {
    if (!done.isCompleted) done.completeError(const SyncTransportCancelled());
  });
  try {
    if (!stop.cancelled)
      subscription = stream.listen(
        (chunk) {
          if (done.isCompleted) return;
          try {
            if (chunk.isNotEmpty) onProgress();
            if (chunk.length > limit - size) throw syncInvalidWire;
            buffer.setRange(size, size + chunk.length, chunk);
            size += chunk.length;
          } catch (error, stack) {
            done.completeError(error, stack);
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
    await done.future;
    retained = true;
    return Uint8List.sublistView(buffer, 0, size);
  } finally {
    remove();
    if (!retained) {
      buffer.fillRange(0, buffer.length, 0);
      final cancellation = subscription?.cancel();
      if (cancellation != null)
        unawaited(cancellation.catchError((Object _) {}));
    }
  }
}
