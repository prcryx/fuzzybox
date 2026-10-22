import 'dart:convert';

/// Represents a document stored within [FuzzyBox].
///
/// Combines the speed of a key-value store with the expressiveness of a
/// structured document. Supports nested JSON payloads, tags for secondary
/// indexing, and typed accessors.
class ConfigDoc {
  /// The unique key identifying this document (e.g. 'theme.palette', 'auth.tokens').
  final String key;

  /// The raw payload: can be a primitive (bool, int, double, String), or a [Map] / [List].
  final dynamic value;

  /// Indexable tags for fast category/group queries (e.g. {'feature_flag', 'offline'}).
  final Set<String> tags;

  /// Optional schema identifier for type classification (e.g. 'UserPreference').
  final String? schema;

  /// Timestamp when the document was first created.
  final DateTime createdAt;

  /// Timestamp when the document was last updated.
  final DateTime updatedAt;

  /// Monotonically increasing revision number for optimistic concurrency.
  final int version;

  ConfigDoc({
    required this.key,
    required this.value,
    Iterable<String>? tags,
    this.schema,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.version = 1,
  }) : tags = Set<String>.unmodifiable(tags?.toSet() ?? const <String>{}),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// Creates a copy of this document with updated fields and incremented version.
  ConfigDoc copyWith({
    dynamic value,
    Iterable<String>? tags,
    String? schema,
    DateTime? updatedAt,
    int? version,
  }) {
    return ConfigDoc(
      key: key,
      value: value ?? this.value,
      tags: tags ?? this.tags,
      schema: schema ?? this.schema,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      version: version ?? (this.version + 1),
    );
  }

  // ===========================================================================
  // Convenient Typed Accessors for Top-level or Nested Values
  // ===========================================================================

  /// Returns the value cast to a [Map<String, dynamic>], or an empty map if not applicable.
  Map<String, dynamic> asMap() {
    if (value is Map) {
      return Map<String, dynamic>.from(value as Map);
    }
    return <String, dynamic>{};
  }

  /// Returns the value cast to a [List<dynamic>], or an empty list if not applicable.
  List<dynamic> asList() {
    if (value is List) {
      return List<dynamic>.from(value as List);
    }
    return <dynamic>[];
  }

  /// Resolves a nested value using dot notation (e.g. 'user.profile.age').
  ///
  /// If [path] is empty or '.', returns [value].
  dynamic resolvePath(String path) {
    if (path.isEmpty || path == '.') return value;

    final segments = path.split('.');
    dynamic current = value;

    for (final segment in segments) {
      if (current == null) return null;

      if (current is Map) {
        current = current[segment];
      } else if (current is List) {
        final index = int.tryParse(segment);
        if (index != null && index >= 0 && index < current.length) {
          current = current[index];
        } else {
          return null;
        }
      } else {
        return null;
      }
    }
    return current;
  }

  /// Extracts a String from [path] (or root if null), falling back to [fallback].
  String getString([String? path, String fallback = '']) {
    final v = path == null ? value : resolvePath(path);
    if (v == null) return fallback;
    return v.toString();
  }

  /// Extracts an int from [path] (or root if null), falling back to [fallback].
  int getInt([String? path, int fallback = 0]) {
    final v = path == null ? value : resolvePath(path);
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  /// Extracts a double from [path] (or root if null), falling back to [fallback].
  double getDouble([String? path, double fallback = 0.0]) {
    final v = path == null ? value : resolvePath(path);
    if (v is double) return v;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  /// Extracts a bool from [path] (or root if null), falling back to [fallback].
  bool getBool([String? path, bool fallback = false]) {
    final v = path == null ? value : resolvePath(path);
    if (v is bool) return v;
    if (v is String) {
      final lower = v.toLowerCase();
      if (lower == 'true' || lower == '1' || lower == 'yes') return true;
      if (lower == 'false' || lower == '0' || lower == 'no') return false;
    }
    if (v is num) return v != 0;
    return fallback;
  }

  /// Extracts a [DateTime] from [path] (or root if null).
  DateTime? getDateTime([String? path]) {
    final v = path == null ? value : resolvePath(path);
    if (v is DateTime) return v;
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  // ===========================================================================
  // Serialization
  // ===========================================================================

  /// Serializes this document to a JSON-compatible map.
  Map<String, dynamic> toMap() {
    return {
      'k': key,
      'v': value,
      't': tags.toList(),
      if (schema != null) 's': schema,
      'c': createdAt.millisecondsSinceEpoch,
      'u': updatedAt.millisecondsSinceEpoch,
      'ver': version,
    };
  }

  /// Deserializes a document from a JSON-compatible map.
  factory ConfigDoc.fromMap(Map<String, dynamic> map) {
    return ConfigDoc(
      key: map['k'] as String,
      value: map['v'],
      tags: (map['t'] as List?)?.map((e) => e.toString()).toSet() ?? const {},
      schema: map['s'] as String?,
      createdAt: map['c'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['c'] as int)
          : null,
      updatedAt: map['u'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['u'] as int)
          : null,
      version: (map['ver'] as int?) ?? 1,
    );
  }

  /// Encodes document to compact JSON string.
  String toJson() => jsonEncode(toMap());

  /// Decodes document from JSON string.
  factory ConfigDoc.fromJson(String source) =>
      ConfigDoc.fromMap(jsonDecode(source) as Map<String, dynamic>);

  @override
  String toString() =>
      'ConfigDoc(key: $key, schema: $schema, version: $version, tags: $tags, value: $value)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConfigDoc &&
          runtimeType == other.runtimeType &&
          key == other.key &&
          version == other.version &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => key.hashCode ^ version.hashCode ^ updatedAt.hashCode;
}
