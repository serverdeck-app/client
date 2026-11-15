import 'dart:io';

import 'package:commons_validator/commons_validator.dart' show unicodeToAscii;

import '../domain/models.dart';
import 'sync_models.dart' show normalizeSyncHost;
import 'sync_wire.dart';

typedef SyncOriginNormalizer = SyncServiceOrigin Function(String input);

/// Pure setting boundary. IDNA-2003/nameprep, shared on Windows and Android;
/// the canonical ASCII target must be displayed before any user consent.
SyncServiceOrigin normalizeSyncServiceOrigin(String input) {
  const invalid = OperationFailure(FailureCode.invalidArgument);
  try {
    if (input.length > 2048 ||
        !isWellFormedUnicode(input) ||
        RegExp(r'[\p{Cc}\p{Cf}\p{Cs}]', unicode: true).hasMatch(input))
      throw invalid;
    final match = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]+)(/?)$')
        .firstMatch(input.trim());
    if (match == null || match[1]!.toLowerCase() != 'https') throw invalid;
    final authority = match[2]!;
    if (RegExp(r'[@%\\\s]').hasMatch(authority)) throw invalid;
    final hostPort = authority.startsWith('[')
        ? RegExp(r'^\[([0-9a-fA-F:.]+)\](?::([0-9]{1,5}))?$')
              .firstMatch(authority)
        : RegExp(r'^([^:]+)(?::([0-9]{1,5}))?$').firstMatch(authority);
    if (hostPort == null) throw invalid;
    final port = hostPort[2] == null ? 443 : int.parse(hostPort[2]!);
    if (port < 1 || port > 65535) throw invalid;
    String host;
    if (authority.startsWith('[')) {
      final ip = InternetAddress.tryParse(hostPort[1]!);
      if (ip == null || ip.type != InternetAddressType.IPv6) throw invalid;
      host = InternetAddress.fromRawAddress(
        ip.rawAddress,
        type: ip.type,
      ).address.toLowerCase();
    } else {
      final ascii = unicodeToAscii(hostPort[1]!);
      if (!RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(ascii)) throw invalid;
      host = normalizeSyncHost(ascii);
    }
    return SyncServiceOrigin(
      Uri(scheme: 'https', host: host, port: port == 443 ? null : port).origin,
    );
  } on OperationFailure {
    throw invalid;
  } catch (_) {
    throw invalid;
  }
}
