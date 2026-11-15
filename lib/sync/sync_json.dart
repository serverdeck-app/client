import 'dart:convert';
import 'dart:typed_data';

import '../domain/models.dart';

const _invalidJson = OperationFailure(FailureCode.invalidArgument);
const _maxInteger = 9007199254740991;

/// Credential bytes are data: unlike JSON, a leading U+FEFF is not discarded.
String decodeSyncUtf8Exact(Uint8List bytes) {
  try {
    final value = utf8.decode(bytes, allowMalformed: false);
    return bytes.length >= 3 &&
            bytes[0] == 0xef &&
            bytes[1] == 0xbb &&
            bytes[2] == 0xbf
        ? '\ufeff$value'
        : value;
  } catch (_) {
    throw _invalidJson;
  }
}

/// Bounded format decoder. Unlike jsonDecode, duplicate object keys are errors.
Object? strictSyncJson(
  Uint8List bytes, {
  required int maxBytes,
  bool canonical = false,
}) {
  if (bytes.length > maxBytes ||
      maxBytes < 1 ||
      (bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf))
    throw _invalidJson;
  try {
    final value = _Parser(utf8.decode(bytes, allowMalformed: false)).parse();
    if (canonical) {
      final encoded = canonicalSyncJson(value);
      try {
        if (encoded.length != bytes.length) throw _invalidJson;
        for (var i = 0; i < bytes.length; i++) {
          if (encoded[i] != bytes[i]) throw _invalidJson;
        }
      } finally {
        encoded.fillRange(0, encoded.length, 0);
      }
    }
    return value;
  } catch (_) {
    throw _invalidJson;
  }
}

Uint8List canonicalSyncJson(Object? value) {
  Object? normalize(Object? node, int depth) {
    if (depth > 64) throw _invalidJson;
    if (node == null || node is bool) return node;
    if (node is int) {
      if (node < -_maxInteger || node > _maxInteger) throw _invalidJson;
      return node;
    }
    if (node is String) {
      if (!isWellFormedUnicode(node)) throw _invalidJson;
      return node;
    }
    if (node is List)
      return node.map((item) => normalize(item, depth + 1)).toList();
    if (node is Map<String, Object?>) {
      final keys = node.keys.toList()..sort();
      if (keys.any(
        (key) => key.isEmpty || RegExp(r'[^\x20-\x7e]').hasMatch(key),
      ))
        throw _invalidJson;
      return {for (final key in keys) key: normalize(node[key], depth + 1)};
    }
    throw _invalidJson;
  }

  try {
    return utf8.encode(jsonEncode(normalize(value, 0)));
  } on OperationFailure {
    rethrow;
  } catch (_) {
    throw _invalidJson;
  }
}

final class _Parser {
  _Parser(this.source);
  final String source;
  int index = 0;
  Object? parse() {
    final value = _value(0);
    _space();
    if (index != source.length) throw _invalidJson;
    return value;
  }

  void _space() {
    while (index < source.length &&
        const [32, 9, 10, 13].contains(source.codeUnitAt(index))) {
      index++;
    }
  }

  bool _take(int unit) {
    _space();
    if (index < source.length && source.codeUnitAt(index) == unit) {
      index++;
      return true;
    }
    return false;
  }

  Object? _value(int depth) {
    if (depth > 64) throw _invalidJson;
    _space();
    if (index >= source.length) throw _invalidJson;
    final unit = source.codeUnitAt(index);
    if (unit == 34) return _string();
    if (unit == 123) {
      index++;
      final map = <String, Object?>{};
      if (_take(125)) return map;
      do {
        _space();
        if (index >= source.length || source.codeUnitAt(index) != 34)
          throw _invalidJson;
        final key = _string();
        if (map.containsKey(key) || !_take(58)) throw _invalidJson;
        map[key] = _value(depth + 1);
        if (_take(125)) return map;
      } while (_take(44));
      throw _invalidJson;
    }
    if (unit == 91) {
      index++;
      final list = <Object?>[];
      if (_take(93)) return list;
      do {
        list.add(_value(depth + 1));
        if (_take(93)) return list;
      } while (_take(44));
      throw _invalidJson;
    }
    for (final entry in const {
      'true': true,
      'false': false,
      'null': null,
    }.entries) {
      if (source.startsWith(entry.key, index)) {
        index += entry.key.length;
        return entry.value;
      }
    }
    final start = index;
    if (unit == 45) index++;
    if (index >= source.length) throw _invalidJson;
    if (source.codeUnitAt(index) == 48) {
      index++;
    } else {
      if (source.codeUnitAt(index) < 49 || source.codeUnitAt(index) > 57)
        throw _invalidJson;
      while (index < source.length &&
          source.codeUnitAt(index) >= 48 &&
          source.codeUnitAt(index) <= 57) {
        index++;
      }
    }
    final token = source.substring(start, index);
    final number = int.tryParse(token);
    if (number == null ||
        number < -_maxInteger ||
        number > _maxInteger ||
        token == '-0')
      throw _invalidJson;
    return number;
  }

  String _string() {
    final start = index++;
    while (index < source.length) {
      final unit = source.codeUnitAt(index++);
      if (unit == 34) {
        final value = jsonDecode(source.substring(start, index)) as String;
        if (!isWellFormedUnicode(value)) throw _invalidJson;
        return value;
      }
      if (unit < 32) throw _invalidJson;
      if (unit == 92) {
        if (index >= source.length) throw _invalidJson;
        index++; // jsonDecode validates escape spelling and surrogate pairs.
      }
    }
    throw _invalidJson;
  }
}
