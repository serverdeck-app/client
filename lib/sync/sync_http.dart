import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'sync_wire.dart';

/// Body is borrowed for this call only. Ports must not retain it after cancel.
final class SyncHttpRequest {
  SyncHttpRequest(
    this.method,
    this.uri,
    Map<String, String> headers,
    Uint8List? body,
  ) : headers = Map.unmodifiable(headers),
      body = body?.asUnmodifiableView();
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Uint8List? body;
}

final class SyncHttpResponse {
  SyncHttpResponse(this.status, Map<String, List<String>> headers, this.body)
    : headers = _headers(headers);
  static Map<String, List<String>> _headers(Map<String, List<String>> input) {
    final merged = <String, List<String>>{};
    input.forEach(
      (key, values) => (merged[key.toLowerCase()] ??= []).addAll(values),
    );
    return Map.unmodifiable(
      merged.map(
        (key, values) => MapEntry(key, List<String>.unmodifiable(values)),
      ),
    );
  }

  final int status;
  final Map<String, List<String>> headers;
  final Stream<List<int>> body;
}

abstract interface class SyncHttpCall {
  Future<SyncHttpResponse> get response;
  void cancel();
}

abstract interface class SyncHttpPort {
  SyncHttpCall send(
    SyncHttpRequest request, {
    required void Function() onProgress,
  });
}

/// One client per operation allows force-closing DNS/connect/write/read on cancel
/// without disturbing another captured identity. No cookies, custom trust hook,
/// redirect, retry, decompression or fallback is configured.
final class DartSyncHttpPort implements SyncHttpPort {
  DartSyncHttpPort({HttpClient Function()? createClient})
    : _create = createClient ?? HttpClient.new;
  final HttpClient Function() _create;
  @override
  SyncHttpCall send(
    SyncHttpRequest request, {
    required void Function() onProgress,
  }) {
    if (request.uri.scheme != 'https' || request.uri.userInfo.isNotEmpty)
      throw syncInvalidWire;
    return _DartCall(_create(), request, onProgress);
  }
}

final class _DartCall implements SyncHttpCall {
  _DartCall(this._client, SyncHttpRequest request, void Function() onProgress) {
    _client.autoUncompress = false;
    response = _send(request, onProgress);
  }
  final HttpClient _client;
  bool _cancelled = false;
  @override
  late final Future<SyncHttpResponse> response;
  Future<SyncHttpResponse> _send(
    SyncHttpRequest input,
    void Function() onProgress,
  ) async {
    final request = await _client.openUrl(input.method, input.uri);
    if (_cancelled) {
      request.abort();
      throw syncInvalidWire;
    }
    request.followRedirects = false;
    request.maxRedirects = 0;
    request.persistentConnection = false;
    input.headers.forEach(request.headers.set);
    request.contentLength = input.body?.length ?? 0;
    final body = input.body;
    if (body != null) {
      for (var offset = 0; offset < body.length; offset += 16384) {
        if (_cancelled) throw syncInvalidWire;
        request.add(
          Uint8List.sublistView(
            body,
            offset,
            (offset + 16384).clamp(0, body.length),
          ),
        );
        await request.flush();
        onProgress();
      }
    }
    final result = await request.close();
    if (_cancelled) throw syncInvalidWire;
    final headers = <String, List<String>>{};
    result.headers.forEach((name, values) => headers[name] = List.of(values));
    return SyncHttpResponse(result.statusCode, headers, result);
  }

  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _client.close(force: true);
  }
}
