import '../domain/models.dart';
import '../storage/domain_repository.dart';
import '../storage/records.dart';
import 'credential_input.dart';

/// Shared native transaction helper. Never imports trust from another device.
abstract final class EndpointReferences {
  static const _bad = OperationFailure(FailureCode.storageUnavailable);

  static EndpointTrust _existing(DomainRead records, String id) {
    final value = records.endpoint(id);
    if (value == null ||
        value.profileRefCount < 1 ||
        value.profileRefCount > 1000 ||
        value.trustRevision < 1 ||
        value.trustRevision > 9007199254740991 ||
        value.observationRevision < 1 ||
        value.observationRevision > 9007199254740991) {
      throw _bad;
    }
    return value;
  }

  static void add(DomainTransaction records, ValidatedProfileFields fields) {
    final previous = records.endpoint(fields.endpointId);
    final value = previous == null
        ? (EndpointTrust()
            ..endpointId = fields.endpointId
            ..normalizedHost = fields.normalizedHost
            ..port = fields.port)
        : _existing(records, fields.endpointId);
    if (value.normalizedHost != fields.normalizedHost ||
        value.port != fields.port ||
        value.profileRefCount >= 1000) {
      throw _bad;
    }
    value.profileRefCount++;
    records.putEndpoint(value);
  }

  static void remove(DomainTransaction records, String id) {
    final value = _existing(records, id);
    if (value.profileRefCount == 1) {
      records.deleteEndpoint(id);
    } else {
      value.profileRefCount--;
      records.putEndpoint(value);
    }
  }

  /// Complete before/after profile sets under the caller's guarded transaction.
  /// Apply net counts so replacing a last profile with another at the same
  /// endpoint retains that endpoint's local trust throughout the atomic batch.
  static void reconcile(
    DomainTransaction records, {
    required List<Profile> before,
    required List<Profile> after,
  }) {
    final (updates, removed) = _plan(records, before: before, after: after);
    for (final id in removed) {
      records.deleteEndpoint(id);
    }
    for (final value in updates) {
      records.putEndpoint(value);
    }
  }

  static void validateBatch(
    DomainRead records, {
    required List<Profile> before,
    required List<Profile> after,
  }) {
    _plan(records, before: before, after: after);
  }

  static (List<EndpointTrust>, List<String>) _plan(
    DomainRead records, {
    required List<Profile> before,
    required List<Profile> after,
  }) {
    final old = _index(before), next = _index(after);
    final updates = <EndpointTrust>[], removed = <String>[];
    for (final id in {...old.keys, ...next.keys}) {
      final prior = old[id], desired = next[id];
      final stored = records.endpoint(id);
      EndpointTrust? value;
      if (prior == null) {
        if (stored != null) throw _bad;
      } else {
        value = _existing(records, id);
        if (value.profileRefCount != prior.$2 ||
            value.normalizedHost != prior.$1.normalizedHost ||
            value.port != prior.$1.port) {
          throw _bad;
        }
      }
      if (desired == null) {
        removed.add(id);
      } else {
        value ??= EndpointTrust()
          ..endpointId = id
          ..normalizedHost = desired.$1.normalizedHost
          ..port = desired.$1.port;
        if (value.normalizedHost != desired.$1.normalizedHost ||
            value.port != desired.$1.port)
          throw _bad;
        if (prior?.$2 != desired.$2) {
          value.profileRefCount = desired.$2;
          updates.add(value);
        }
      }
    }
    return (updates, removed);
  }

  static Map<String, (ValidatedProfileFields, int)> _index(
    List<Profile> values,
  ) {
    if (values.length > 1000) throw _bad;
    final result = <String, (ValidatedProfileFields, int)>{}, ids = <String>{};
    for (final value in values) {
      if (!isCanonicalUuid(value.profileId) || !ids.add(value.profileId))
        throw _bad;
      final fields = validateProfileValues(
        displayName: value.displayName,
        host: value.originalHost,
        port: value.port,
        username: value.username,
      );
      if (fields.endpointId != value.endpointId ||
          fields.normalizedHost != value.normalizedHost)
        throw _bad;
      final old = result[value.endpointId];
      result[value.endpointId] = (fields, (old?.$2 ?? 0) + 1);
    }
    return result;
  }
}
