import 'dart:convert';

import 'package:serverdeck/software/software_models.dart';
import 'package:serverdeck/storage/records.dart';

/// Synthetic record accepted by the previous contract at its exact byte limit.
SoftwareCardRecord legacyMaxCard(Profile p, String id) {
  final card = SoftwareCardRecord()
    ..softwareId = id
    ..profileId = p.profileId
    ..endpointId = p.endpointId
    ..host = p.normalizedHost
    ..port = p.port
    ..username = p.username
    ..name = 'Legacy boundary'
    ..dataPaths = List.generate(
      16,
      (i) => '/${i.toString().padLeft(2, '0')}${'a' * 1021}',
    )
    ..configPaths = [
      ...List.generate(
        15,
        (i) => '/${i.toString().padLeft(2, '0')}${'b' * 1021}',
      ),
      '/',
    ];
  final old = SoftwareCardView(card, currentTarget: true).toJson()
    ..remove('updateInstructions');
  final padding = 32768 - utf8.encode(jsonEncode(old)).length;
  if (padding < 0 || padding > 1023) throw StateError('Invalid legacy fixture');
  card.configPaths[15] += 'c' * padding;
  return card;
}
