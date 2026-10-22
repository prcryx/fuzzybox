import 'dart:async';
import 'config_doc.dart';

/// Defines comparison operators for document property queries.
enum QueryOperator {
  equals,
  notEquals,
  greaterThan,
  greaterThanOrEqual,
  lessThan,
  lessThanOrEqual,
  contains,
  isIn,
  isNotIn,
  startsWith,
  endsWith,
}

/// A single property condition to evaluate against a document.
class PropertyCondition {
  final String path;
  final QueryOperator operator;
  final dynamic targetValue;

  const PropertyCondition({
    required this.path,
    required this.operator,
    required this.targetValue,
  });

  bool matches(ConfigDoc doc) {
    final actual = doc.resolvePath(path);

    switch (operator) {
      case QueryOperator.equals:
        return actual == targetValue;
      case QueryOperator.notEquals:
        return actual != targetValue;
      case QueryOperator.greaterThan:
        if (actual is num && targetValue is num) {
          return actual > targetValue;
        }
        if (actual is String && targetValue is String) {
          return actual.compareTo(targetValue) > 0;
        }
        return false;
      case QueryOperator.greaterThanOrEqual:
        if (actual is num && targetValue is num) {
          return actual >= targetValue;
        }
        if (actual is String && targetValue is String) {
          return actual.compareTo(targetValue) >= 0;
        }
        return false;
      case QueryOperator.lessThan:
        if (actual is num && targetValue is num) {
          return actual < targetValue;
        }
        if (actual is String && targetValue is String) {
          return actual.compareTo(targetValue) < 0;
        }
        return false;
      case QueryOperator.lessThanOrEqual:
        if (actual is num && targetValue is num) {
          return actual <= targetValue;
        }
        if (actual is String && targetValue is String) {
          return actual.compareTo(targetValue) <= 0;
        }
        return false;
      case QueryOperator.contains:
        if (actual is String && targetValue is String) {
          return actual.contains(targetValue);
        }
        if (actual is Iterable) {
          return actual.contains(targetValue);
        }
        return false;
      case QueryOperator.isIn:
        if (targetValue is Iterable) {
          return (targetValue as Iterable).contains(actual);
        }
        return false;
      case QueryOperator.isNotIn:
        if (targetValue is Iterable) {
          return !(targetValue as Iterable).contains(actual);
        }
        return true;
      case QueryOperator.startsWith:
        if (actual is String && targetValue is String) {
          return actual.startsWith(targetValue);
        }
        return false;
      case QueryOperator.endsWith:
        if (actual is String && targetValue is String) {
          return actual.endsWith(targetValue);
        }
        return false;
    }
  }
}

/// A fluent, lightweight query builder for [FuzzyBox].
///
/// Executes against the in-memory index for sub-millisecond query performance
/// on mobile devices, with zero external database engine overhead.
class DocQuery {
  final List<ConfigDoc> Function() _documentSource;
  final Stream<void> _changeSignal;

  String? _keyPrefix;
  String? _schema;
  final Set<String> _requiredTags = {};
  final Set<String> _anyTags = {};
  final List<PropertyCondition> _conditions = [];
  bool Function(ConfigDoc doc)? _customFilter;

  String? _orderProperty;
  bool _descending = false;
  int? _limitCount;
  int _offsetCount = 0;

  DocQuery({
    required List<ConfigDoc> Function() documentSource,
    required Stream<void> changeSignal,
  }) : _documentSource = documentSource,
       _changeSignal = changeSignal;

  /// Filters documents where the key starts with [prefix].
  DocQuery whereKeyStartsWith(String prefix) {
    _keyPrefix = prefix;
    return this;
  }

  /// Filters documents belonging to [schema].
  DocQuery whereSchema(String schema) {
    _schema = schema;
    return this;
  }

  /// Filters documents that have the specified [tag].
  DocQuery whereTag(String tag) {
    _requiredTags.add(tag);
    return this;
  }

  /// Filters documents that contain ALL of the [tags].
  DocQuery whereAllTags(Iterable<String> tags) {
    _requiredTags.addAll(tags);
    return this;
  }

  /// Filters documents that contain AT LEAST ONE of the [tags].
  DocQuery whereAnyTag(Iterable<String> tags) {
    _anyTags.addAll(tags);
    return this;
  }

  /// Evaluates an equality condition on [path].
  DocQuery whereEquals(String path, dynamic value) {
    _conditions.add(
      PropertyCondition(
        path: path,
        operator: QueryOperator.equals,
        targetValue: value,
      ),
    );
    return this;
  }

  /// Evaluates an inequality condition on [path].
  DocQuery whereNotEquals(String path, dynamic value) {
    _conditions.add(
      PropertyCondition(
        path: path,
        operator: QueryOperator.notEquals,
        targetValue: value,
      ),
    );
    return this;
  }

  /// Evaluates greater-than on [path].
  DocQuery whereGreaterThan(String path, dynamic value) {
    _conditions.add(
      PropertyCondition(
        path: path,
        operator: QueryOperator.greaterThan,
        targetValue: value,
      ),
    );
    return this;
  }

  /// Evaluates greater-than-or-equal on [path].
  DocQuery whereGreaterThanOrEqual(String path, dynamic value) {
    _conditions.add(
      PropertyCondition(
        path: path,
        operator: QueryOperator.greaterThanOrEqual,
        targetValue: value,
      ),
    );
    return this;
  }

  /// Evaluates less-than on [path].
  DocQuery whereLessThan(String path, dynamic value) {
    _conditions.add(
      PropertyCondition(
        path: path,
        operator: QueryOperator.lessThan,
        targetValue: value,
      ),
    );
    return this;
  }

  /// Evaluates less-than-or-equal on [path].
  DocQuery whereLessThanOrEqual(String path, dynamic value) {
    _conditions.add(
      PropertyCondition(
        path: path,
        operator: QueryOperator.lessThanOrEqual,
        targetValue: value,
      ),
    );
    return this;
  }

  /// Evaluates whether a String or List at [path] contains [value].
  DocQuery whereContains(String path, dynamic value) {
    _conditions.add(
      PropertyCondition(
        path: path,
        operator: QueryOperator.contains,
        targetValue: value,
      ),
    );
    return this;
  }

  /// Evaluates whether the value at [path] is contained in [allowedValues].
  DocQuery whereIn(String path, Iterable<dynamic> allowedValues) {
    _conditions.add(
      PropertyCondition(
        path: path,
        operator: QueryOperator.isIn,
        targetValue: allowedValues,
      ),
    );
    return this;
  }

  /// Appends a custom pure Dart boolean predicate.
  DocQuery filter(bool Function(ConfigDoc doc) predicate) {
    _customFilter = predicate;
    return this;
  }

  /// Orders results by document [path] (or '.' for primitive value, 'key', 'updatedAt').
  DocQuery orderBy(String path, {bool descending = false}) {
    _orderProperty = path;
    _descending = descending;
    return this;
  }

  /// Orders results by key.
  DocQuery orderByKey({bool descending = false}) {
    _orderProperty = 'key';
    _descending = descending;
    return this;
  }

  /// Orders results by last updated timestamp.
  DocQuery orderByUpdatedAt({bool descending = true}) {
    _orderProperty = 'updatedAt';
    _descending = descending;
    return this;
  }

  /// Limits the number of returned documents.
  DocQuery limit(int count) {
    _limitCount = count;
    return this;
  }

  /// Skips the first [count] matching documents.
  DocQuery offset(int count) {
    _offsetCount = count;
    return this;
  }

  // ===========================================================================
  // Execution Methods
  // ===========================================================================

  /// Executes the query and returns all matching documents.
  List<ConfigDoc> find() {
    final docs = _documentSource();
    var filtered = docs.where(_matches).toList();

    // Sort if specified
    if (_orderProperty != null) {
      filtered.sort((a, b) {
        dynamic valA;
        dynamic valB;

        if (_orderProperty == 'key') {
          valA = a.key;
          valB = b.key;
        } else if (_orderProperty == 'updatedAt') {
          valA = a.updatedAt.millisecondsSinceEpoch;
          valB = b.updatedAt.millisecondsSinceEpoch;
        } else if (_orderProperty == 'createdAt') {
          valA = a.createdAt.millisecondsSinceEpoch;
          valB = b.createdAt.millisecondsSinceEpoch;
        } else {
          valA = a.resolvePath(_orderProperty!);
          valB = b.resolvePath(_orderProperty!);
        }

        int cmp;
        if (valA == null && valB == null) {
          cmp = 0;
        } else if (valA == null) {
          cmp = -1;
        } else if (valB == null) {
          cmp = 1;
        } else if (valA is Comparable && valB is Comparable) {
          try {
            cmp = valA.compareTo(valB);
          } catch (_) {
            cmp = valA.toString().compareTo(valB.toString());
          }
        } else {
          cmp = valA.toString().compareTo(valB.toString());
        }

        return _descending ? -cmp : cmp;
      });
    }

    // Offset
    if (_offsetCount > 0) {
      if (_offsetCount >= filtered.length) {
        return const [];
      }
      filtered = filtered.sublist(_offsetCount);
    }

    // Limit
    if (_limitCount != null && _limitCount! < filtered.length) {
      filtered = filtered.sublist(0, _limitCount!);
    }

    return filtered;
  }

  /// Returns the first matching document, or null if no match.
  ConfigDoc? findFirst() {
    final results = limit(1).find();
    return results.isEmpty ? null : results.first;
  }

  /// Counts the total number of documents matching the query (without pagination limits).
  int count() {
    final docs = _documentSource();
    return docs.where(_matches).length;
  }

  /// Returns a live reactive [Stream] of matching results whenever storage changes.
  Stream<List<ConfigDoc>> watch() {
    late StreamController<List<ConfigDoc>> controller;
    StreamSubscription? sub;

    void emit() {
      if (!controller.isClosed) {
        controller.add(find());
      }
    }

    controller = StreamController<List<ConfigDoc>>.broadcast(
      onListen: () {
        emit();
        sub = _changeSignal.listen((_) => emit());
      },
      onCancel: () {
        sub?.cancel();
      },
    );

    return controller.stream;
  }

  bool _matches(ConfigDoc doc) {
    if (_keyPrefix != null && !doc.key.startsWith(_keyPrefix!)) {
      return false;
    }
    if (_schema != null && doc.schema != _schema) {
      return false;
    }
    if (_requiredTags.isNotEmpty && !_requiredTags.every(doc.tags.contains)) {
      return false;
    }
    if (_anyTags.isNotEmpty && !_anyTags.any(doc.tags.contains)) {
      return false;
    }
    for (final condition in _conditions) {
      if (!condition.matches(doc)) {
        return false;
      }
    }
    if (_customFilter != null && !_customFilter!(doc)) {
      return false;
    }
    return true;
  }
}
