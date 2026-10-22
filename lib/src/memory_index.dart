import 'config_doc.dart';

/// In-memory primary and secondary indices for [FuzzyBox].
///
/// Provides O(1) key lookups (like SharedPreferences) while maintaining
/// an inverted tag index and structured collection for instant query performance.
class MemoryIndex {
  /// Primary index: key -> document.
  final Map<String, ConfigDoc> _documents = {};

  /// Inverted secondary index: tag -> Set of keys having that tag.
  final Map<String, Set<String>> _tagIndex = {};

  /// Returns total number of active documents.
  int get length => _documents.length;

  /// Returns all active document keys.
  Iterable<String> get keys => _documents.keys;

  /// Returns all active documents.
  List<ConfigDoc> get allDocuments => _documents.values.toList();

  /// Gets a document by its primary key in O(1) time.
  ConfigDoc? get(String key) => _documents[key];

  /// Checks if a key exists in O(1) time.
  bool containsKey(String key) => _documents.containsKey(key);

  /// Inserts or updates a document, updating primary and tag indexes.
  void put(ConfigDoc doc) {
    final existing = _documents[doc.key];
    if (existing != null) {
      _removeFromTagIndex(existing);
    }

    _documents[doc.key] = doc;
    _addToTagIndex(doc);
  }

  /// Removes a document by key, updating primary and tag indexes.
  ConfigDoc? remove(String key) {
    final doc = _documents.remove(key);
    if (doc != null) {
      _removeFromTagIndex(doc);
    }
    return doc;
  }

  /// Clears all indices.
  void clear() {
    _documents.clear();
    _tagIndex.clear();
  }

  /// Fast indexed tag lookup: returns all documents tagged with [tag].
  List<ConfigDoc> getByTag(String tag) {
    final keySet = _tagIndex[tag];
    if (keySet == null || keySet.isEmpty) return const [];
    return keySet.map((k) => _documents[k]!).whereType<ConfigDoc>().toList();
  }

  /// Fast prefix search: returns documents whose keys start with [prefix].
  List<ConfigDoc> getByPrefix(String prefix) {
    return _documents.values
        .where((doc) => doc.key.startsWith(prefix))
        .toList();
  }

  void _addToTagIndex(ConfigDoc doc) {
    for (final tag in doc.tags) {
      _tagIndex.putIfAbsent(tag, () => <String>{}).add(doc.key);
    }
  }

  void _removeFromTagIndex(ConfigDoc doc) {
    for (final tag in doc.tags) {
      final set = _tagIndex[tag];
      if (set != null) {
        set.remove(doc.key);
        if (set.isEmpty) {
          _tagIndex.remove(tag);
        }
      }
    }
  }
}
