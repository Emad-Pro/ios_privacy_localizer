import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../exceptions/localizer_exception.dart';
import '../models/localizer_config.dart';

/// Generates a stable 24-character uppercase hexadecimal Xcode object ID.
///
/// The same [seed] always yields the same ID, which keeps repeated runs
/// idempotent and diffs reproducible across machines.
String generateDeterministicId(String seed) {
  final bytes = utf8.encode('ios_privacy_localizer:$seed');
  final digest = md5.convert(bytes).toString().toUpperCase();
  return digest.substring(0, 24);
}

/// Deterministic, surgical patcher for `ios/Runner.xcodeproj/project.pbxproj`.
///
/// The file is fully parsed (strings, comments and nesting are understood)
/// to locate objects precisely, but it is edited by inserting text at exact
/// offsets only: no existing byte is ever rewritten or removed. After every
/// insertion the file is parsed again, so a malformed result is detected
/// immediately.
///
/// The patcher ensures that:
/// * an `InfoPlist.strings` `PBXVariantGroup` exists (an existing one, e.g.
///   created by `app_name_localizer` or Xcode, is reused, never duplicated);
/// * it has one `PBXFileReference` child per locale;
/// * it is a child of the `Runner` `PBXGroup`;
/// * a `PBXBuildFile` for it is part of the Runner `PBXResourcesBuildPhase`;
/// * every locale is listed in `knownRegions`.
class PbxprojUpdater {
  const PbxprojUpdater();

  /// File name of the localized resource.
  static const String stringsFileName = 'InfoPlist.strings';

  /// ID used when a new `InfoPlist.strings` variant group must be created.
  static String get variantGroupId =>
      generateDeterministicId('PBXVariantGroup:InfoPlist.strings');

  /// ID used when a new `PBXBuildFile` must be created.
  static String get buildFileId =>
      generateDeterministicId('PBXBuildFile:InfoPlist.strings');

  /// ID used when a new `PBXFileReference` must be created for [locale].
  static String fileRefId(String locale) =>
      generateDeterministicId('PBXFileReference:$locale:InfoPlist.strings');

  /// Returns [source] with every element required for [locales] present.
  ///
  /// When nothing is missing, [source] is returned unchanged and
  /// [FileUpdateResult.changes] is empty.
  FileUpdateResult update(
    String source,
    List<String> locales, {
    String sourceName = 'project.pbxproj',
  }) {
    final session = _PbxEditSession(source, sourceName);
    if (locales.isNotEmpty) {
      session.apply(locales);
    }
    if (session.changes.isEmpty) {
      return FileUpdateResult(source, const <String>[]);
    }
    return FileUpdateResult(
      session.source,
      List<String>.unmodifiable(session.changes),
    );
  }

  /// Quotes [value] the way Xcode does: bare when it only contains
  /// `[A-Za-z0-9_$/:.]`, double-quoted (and escaped) otherwise.
  @visibleForTesting
  static String quote(String value) {
    if (value.isNotEmpty && RegExp(r'^[A-Za-z0-9_$/:.]+$').hasMatch(value)) {
      return value;
    }
    final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }
}

// =============================================================================
// Editing session
// =============================================================================

class _PbxEditSession {
  _PbxEditSession(this.source, this.sourceName)
      : _eol = source.contains('\r\n') ? '\r\n' : '\n' {
    _project = _PbxProject.parse(source, sourceName);
    final (objectIndent, unit) = _detectIndentation();
    _objectIndent = objectIndent;
    _unit = unit;
  }

  String source;
  final String sourceName;
  final String _eol;
  late _PbxProject _project;
  late final String _objectIndent;
  late final String _unit;
  final List<String> changes = <String>[];

  static const String _fileName = PbxprojUpdater.stringsFileName;

  String get _i0 => _objectIndent;
  String get _i1 => '$_objectIndent$_unit';
  String get _i2 => '$_objectIndent$_unit$_unit';

  void apply(List<String> locales) {
    final groupId = _findRunnerGroupId();
    final phaseId = _findResourcesPhaseId();
    final variantGroupId = _resolveVariantGroup(groupId, phaseId);

    for (final locale in locales) {
      _ensureLocale(variantGroupId, locale);
    }

    _ensureArrayItem(
      ownerId: groupId,
      key: 'children',
      value: variantGroupId,
      itemText: '$variantGroupId /* $_fileName */',
      description: 'Attach the $_fileName variant group to the Runner group',
    );

    _ensureBuildFile(variantGroupId, phaseId);
    _ensureKnownRegions(locales);
  }

  // ---------------------------------------------------------------------------
  // Lookups
  // ---------------------------------------------------------------------------

  String _findRunnerGroupId() {
    final groups = _project.idsOfIsa('PBXGroup').toList();

    bool isRunner(String id) {
      final group = _project.byId[id]!;
      return group.string('path') == 'Runner' ||
          group.string('name') == 'Runner';
    }

    bool containsInfoPlist(String id) => _project
            .arrayOf(id, 'children')
            .map((childId) => _project.byId[childId])
            .whereType<_PbxDict>()
            .any((child) {
          final name = child.string('path') ?? child.string('name') ?? '';
          return name == 'Info.plist' || name.endsWith('/Info.plist');
        });

    final runnerGroups = groups.where(isRunner).toList();
    final withInfoPlist = runnerGroups.where(containsInfoPlist).toList();
    if (withInfoPlist.isNotEmpty) {
      return withInfoPlist.first;
    }
    final byPath = runnerGroups
        .where((id) => _project.byId[id]!.string('path') == 'Runner')
        .toList();
    if (byPath.isNotEmpty) {
      return byPath.first;
    }
    if (runnerGroups.isNotEmpty) {
      return runnerGroups.first;
    }
    throw LocalizerPbxprojException(
      '$sourceName: the "Runner" PBXGroup could not be found.',
      path: sourceName,
      hint: 'Use --skip-pbxproj and add InfoPlist.strings in Xcode manually.',
    );
  }

  String _findResourcesPhaseId() {
    final targets = _project.idsOfIsa('PBXNativeTarget').toList();
    String? targetId = targets
        .where((id) => _project.byId[id]!.string('name') == 'Runner')
        .firstOrNull;
    if (targetId == null) {
      final applications = targets
          .where(
            (id) =>
                _project.byId[id]!.string('productType') ==
                'com.apple.product-type.application',
          )
          .toList();
      if (applications.length == 1) {
        targetId = applications.single;
      }
    }
    if (targetId == null) {
      throw LocalizerPbxprojException(
        '$sourceName: the "Runner" PBXNativeTarget could not be found.',
        path: sourceName,
        hint: 'Use --skip-pbxproj and add InfoPlist.strings in Xcode manually.',
      );
    }

    final phaseId = _project
        .arrayOf(targetId, 'buildPhases')
        .where((id) => _project.isaOf(id) == 'PBXResourcesBuildPhase')
        .firstOrNull;
    if (phaseId == null) {
      throw LocalizerPbxprojException(
        '$sourceName: the Runner target has no PBXResourcesBuildPhase.',
        path: sourceName,
        hint: 'Use --skip-pbxproj and add InfoPlist.strings in Xcode manually.',
      );
    }
    return phaseId;
  }

  bool _isStringsVariantGroup(String id) {
    final object = _project.byId[id];
    if (object == null || object.string('isa') != 'PBXVariantGroup') {
      return false;
    }
    return (object.string('name') ?? object.string('path')) == _fileName;
  }

  // ---------------------------------------------------------------------------
  // Step B: PBXVariantGroup
  // ---------------------------------------------------------------------------

  String _resolveVariantGroup(String groupId, String phaseId) {
    final candidates = _project
        .idsOfIsa('PBXVariantGroup')
        .where(_isStringsVariantGroup)
        .toList();

    // 1. Already attached to the Runner group (Xcode, app_name_localizer, or
    //    a previous run of this tool).
    final groupChildren = _project.arrayOf(groupId, 'children').toSet();
    final inGroup = candidates.where(groupChildren.contains).firstOrNull;
    if (inGroup != null) {
      return inGroup;
    }

    // 2. Already part of the Runner resources build phase.
    final phaseFileRefs = _project
        .arrayOf(phaseId, 'files')
        .map((id) => _project.byId[id]?.string('fileRef'))
        .whereType<String>()
        .toSet();
    final inPhase = candidates.where(phaseFileRefs.contains).firstOrNull;
    if (inPhase != null) {
      return inPhase;
    }

    // 3. An orphan (not used by any group or target, so it cannot belong to
    //    an app extension).
    final referenced = <String>{
      ..._project.groupedIds,
      ..._project.buildFileRefs,
    };
    final orphan =
        candidates.where((id) => !referenced.contains(id)).firstOrNull;
    if (orphan != null) {
      return orphan;
    }

    // 4. Create a new one with the deterministic ID.
    final id = PbxprojUpdater.variantGroupId;
    if (_project.byId.containsKey(id)) {
      if (_isStringsVariantGroup(id)) {
        return id;
      }
      throw LocalizerPbxprojException(
        '$sourceName: object ID $id is already used by a '
        '${_project.isaOf(id) ?? 'different'} object.',
        path: sourceName,
      );
    }
    _insertObject(
      'PBXVariantGroup',
      id,
      '$_i0$id /* $_fileName */ = {$_eol'
          '${_i1}isa = PBXVariantGroup;$_eol'
          '${_i1}children = ($_eol'
          '$_i1);$_eol'
          '${_i1}name = $_fileName;$_eol'
          '${_i1}sourceTree = "<group>";$_eol'
          '$_i0};$_eol',
    );
    changes.add('Create PBXVariantGroup "$_fileName" ($id)');
    return id;
  }

  // ---------------------------------------------------------------------------
  // Step A: PBXFileReference per locale
  // ---------------------------------------------------------------------------

  void _ensureLocale(String variantGroupId, String locale) {
    final localizedPath = '$locale.lproj/$_fileName';

    bool matches(String id) {
      final object = _project.byId[id];
      if (object == null || object.string('isa') != 'PBXFileReference') {
        return false;
      }
      final path = object.string('path');
      final name = object.string('name');
      return path == localizedPath ||
          (name == locale && (path ?? '').endsWith(_fileName));
    }

    if (_project.arrayOf(variantGroupId, 'children').any(matches)) {
      return;
    }

    final grouped = _project.groupedIds;
    final orphan = _project
        .idsOfIsa('PBXFileReference')
        .where((id) => matches(id) && !grouped.contains(id))
        .firstOrNull;

    final String fileRefId;
    if (orphan != null) {
      fileRefId = orphan;
    } else {
      fileRefId = PbxprojUpdater.fileRefId(locale);
      if (_project.byId.containsKey(fileRefId)) {
        throw LocalizerPbxprojException(
          '$sourceName: object ID $fileRefId is already used by a '
          '${_project.isaOf(fileRefId) ?? 'different'} object.',
          path: sourceName,
        );
      }
      _insertObject(
        'PBXFileReference',
        fileRefId,
        '$_i0$fileRefId /* $locale */ = {isa = PBXFileReference; '
            'lastKnownFileType = text.plist.strings; '
            'name = ${PbxprojUpdater.quote(locale)}; '
            'path = ${PbxprojUpdater.quote(localizedPath)}; '
            'sourceTree = "<group>"; };$_eol',
      );
      changes.add('Add PBXFileReference for $localizedPath ($fileRefId)');
    }

    _ensureArrayItem(
      ownerId: variantGroupId,
      key: 'children',
      value: fileRefId,
      itemText: '$fileRefId /* $locale */',
      description: 'Add "$locale" to the $_fileName variant group',
    );
  }

  // ---------------------------------------------------------------------------
  // Step D: PBXBuildFile + PBXResourcesBuildPhase
  // ---------------------------------------------------------------------------

  void _ensureBuildFile(String variantGroupId, String phaseId) {
    bool isOurs(String id) {
      final object = _project.byId[id];
      return object != null &&
          object.string('isa') == 'PBXBuildFile' &&
          object.string('fileRef') == variantGroupId;
    }

    if (_project.arrayOf(phaseId, 'files').any(isOurs)) {
      return;
    }

    final phased = _project.phasedBuildFileIds;
    final orphan = _project
        .idsOfIsa('PBXBuildFile')
        .where((id) => isOurs(id) && !phased.contains(id))
        .firstOrNull;

    final String buildFileId;
    if (orphan != null) {
      buildFileId = orphan;
    } else {
      buildFileId = PbxprojUpdater.buildFileId;
      if (_project.byId.containsKey(buildFileId)) {
        throw LocalizerPbxprojException(
          '$sourceName: object ID $buildFileId is already used by a '
          '${_project.isaOf(buildFileId) ?? 'different'} object.',
          path: sourceName,
        );
      }
      _insertObject(
        'PBXBuildFile',
        buildFileId,
        '$_i0$buildFileId /* $_fileName in Resources */ = {isa = PBXBuildFile; '
            'fileRef = $variantGroupId /* $_fileName */; };$_eol',
      );
      changes.add('Add PBXBuildFile "$_fileName in Resources" ($buildFileId)');
    }

    _ensureArrayItem(
      ownerId: phaseId,
      key: 'files',
      value: buildFileId,
      itemText: '$buildFileId /* $_fileName in Resources */',
      description: 'Add $_fileName to the Runner "Copy Bundle Resources" phase',
    );
  }

  // ---------------------------------------------------------------------------
  // Step E: knownRegions
  // ---------------------------------------------------------------------------

  void _ensureKnownRegions(List<String> locales) {
    final projectId = _project.rootObjectId;
    if (projectId == null || _project.isaOf(projectId) != 'PBXProject') {
      throw LocalizerPbxprojException(
        '$sourceName: rootObject does not reference a PBXProject.',
        path: sourceName,
      );
    }

    if (_project.byId[projectId]!.array('knownRegions') == null) {
      final dict = _project.byId[projectId]!;
      final closing = dict.end - 1;
      final lineStart = _lineStart(closing);
      if (source.substring(lineStart, closing).trim().isNotEmpty) {
        throw LocalizerPbxprojException(
          '$sourceName: unable to add knownRegions to the PBXProject object.',
          path: sourceName,
        );
      }
      final items = locales
          .map((locale) => '$_i2${PbxprojUpdater.quote(locale)},$_eol')
          .join();
      _insertAt(lineStart, '${_i1}knownRegions = ($_eol$items$_i1);$_eol');
      changes.add('Add knownRegions (${locales.join(', ')})');
      return;
    }

    for (final locale in locales) {
      _ensureArrayItem(
        ownerId: projectId,
        key: 'knownRegions',
        value: locale,
        itemText: PbxprojUpdater.quote(locale),
        description: 'Add "$locale" to knownRegions',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Text editing primitives
  // ---------------------------------------------------------------------------

  void _ensureArrayItem({
    required String ownerId,
    required String key,
    required String value,
    required String itemText,
    required String description,
  }) {
    final owner = _project.byId[ownerId];
    final array = owner?.array(key);
    if (array == null) {
      throw LocalizerPbxprojException(
        '$sourceName: object $ownerId has no "$key" list.',
        path: sourceName,
      );
    }
    if (array.strings.contains(value)) {
      return;
    }
    _appendToArray(array, itemText);
    changes.add(description);
  }

  void _appendToArray(_PbxArray array, String itemText) {
    final closing = array.end - 1;
    final lineStart = _lineStart(closing);
    final prefix = source.substring(lineStart, closing);

    if (prefix.trim().isEmpty) {
      // Multi-line list: add a new line before the closing parenthesis.
      var indent = '$prefix$_unit';
      if (array.items.isNotEmpty) {
        final last = array.items.last;
        final lastLineStart = _lineStart(last.start);
        final lastPrefix = source.substring(lastLineStart, last.start);
        if (lastPrefix.trim().isEmpty) {
          indent = lastPrefix;
        }
      }
      _insertAt(lineStart, '$indent$itemText,$_eol');
      return;
    }

    // Single-line list such as `(en, Base)`.
    if (array.items.isEmpty) {
      _insertAt(closing, '$itemText, ');
      return;
    }
    final tail =
        _stripComments(source.substring(array.items.last.end, closing));
    _insertAt(closing, tail.contains(',') ? ' $itemText,' : ', $itemText');
  }

  void _insertObject(String isa, String id, String text) {
    final begin = '/* Begin $isa section */';
    final end = '/* End $isa section */';
    var beginIndex = source.indexOf(begin);
    var endIndex = source.indexOf(end);

    if (beginIndex < 0 || endIndex < 0) {
      if (beginIndex >= 0 || endIndex >= 0) {
        throw LocalizerPbxprojException(
          '$sourceName: the $isa section markers are incomplete.',
          path: sourceName,
        );
      }
      _createSection(isa);
      beginIndex = source.indexOf(begin);
      endIndex = source.indexOf(end);
    }
    if (endIndex < beginIndex) {
      throw LocalizerPbxprojException(
        '$sourceName: the $isa section markers are out of order.',
        path: sourceName,
      );
    }

    // Keep Xcode's ascending ID order inside the section.
    var insertAt = _lineStart(endIndex);
    for (final entry in _project.objects.entries) {
      if (entry.start <= beginIndex || entry.start >= endIndex) {
        continue;
      }
      if (entry.key.value.compareTo(id) > 0) {
        final lineStart = _lineStart(entry.start);
        if (source.substring(lineStart, entry.start).trim().isEmpty) {
          insertAt = lineStart;
        }
        break;
      }
    }
    _insertAt(insertAt, text);
  }

  void _createSection(String isa) {
    final begin = '/* Begin $isa section */';
    final end = '/* End $isa section */';
    final objectsStart = _project.objects.start;
    final objectsEnd = _project.objects.end;

    for (final match
        in RegExp(r'/\* Begin (\w+) section \*/').allMatches(source)) {
      if (match.start <= objectsStart || match.start >= objectsEnd) {
        continue;
      }
      if (match.group(1)!.compareTo(isa) > 0) {
        _insertAt(_lineStart(match.start), '$begin$_eol$end$_eol$_eol');
        return;
      }
    }

    final closing = objectsEnd - 1;
    final lineStart = _lineStart(closing);
    if (source.substring(lineStart, closing).trim().isNotEmpty) {
      throw LocalizerPbxprojException(
        '$sourceName: unable to create the $isa section.',
        path: sourceName,
      );
    }
    _insertAt(lineStart, '$_eol$begin$_eol$end$_eol');
  }

  void _insertAt(int offset, String text) {
    source = source.replaceRange(offset, offset, text);
    // Re-parse after every edit: offsets stay exact and any structural
    // problem is detected before the next step.
    _project = _PbxProject.parse(source, sourceName);
  }

  int _lineStart(int offset) {
    if (offset <= 0) {
      return 0;
    }
    return source.lastIndexOf('\n', offset - 1) + 1;
  }

  (String, String) _detectIndentation() {
    final first = _project.objects.entries.firstOrNull;
    if (first == null) {
      return ('\t\t', '\t');
    }
    final lineStart = _lineStart(first.start);
    final indent = source.substring(lineStart, first.start);
    if (indent.isEmpty || indent.trim().isNotEmpty) {
      return ('\t\t', '\t');
    }
    if (indent.startsWith(' ')) {
      final width = indent.length ~/ 2;
      return (indent, ' ' * (width == 0 ? 1 : width));
    }
    return (indent, '\t');
  }

  static String _stripComments(String text) =>
      text.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '').replaceAll(
            RegExp(r'//[^\n]*'),
            '',
          );
}

// =============================================================================
// Project model
// =============================================================================

class _PbxProject {
  _PbxProject._(this.root, this.objects, this.byId);

  factory _PbxProject.parse(String source, String sourceName) {
    final root = _PbxParser(source, sourceName).parseDocument();
    final objects = root.dict('objects');
    if (objects == null) {
      throw LocalizerPbxprojException(
        '$sourceName: the "objects" dictionary is missing.',
        path: sourceName,
      );
    }
    final byId = <String, _PbxDict>{};
    for (final entry in objects.entries) {
      final value = entry.value;
      if (value is _PbxDict) {
        byId[entry.key.value] = value;
      }
    }
    return _PbxProject._(root, objects, byId);
  }

  final _PbxDict root;
  final _PbxDict objects;
  final Map<String, _PbxDict> byId;

  static const Set<String> _groupIsas = <String>{
    'PBXGroup',
    'PBXVariantGroup',
    'XCVersionGroup',
  };

  String? get rootObjectId => root.string('rootObject');

  String? isaOf(String id) => byId[id]?.string('isa');

  Iterable<String> idsOfIsa(String isa) =>
      byId.keys.where((id) => isaOf(id) == isa);

  List<String> arrayOf(String id, String key) =>
      byId[id]?.array(key)?.strings.toList() ?? const <String>[];

  /// IDs listed as `children` of any group.
  Set<String> get groupedIds => <String>{
        for (final id in byId.keys)
          if (_groupIsas.contains(isaOf(id))) ...arrayOf(id, 'children'),
      };

  /// IDs of build files listed in any build phase.
  Set<String> get phasedBuildFileIds => <String>{
        for (final id in byId.keys)
          if (isaOf(id)?.endsWith('BuildPhase') ?? false)
            ...arrayOf(id, 'files'),
      };

  /// `fileRef` targets of every build file.
  Set<String> get buildFileRefs => <String>{
        for (final id in idsOfIsa('PBXBuildFile'))
          if (byId[id]!.string('fileRef') != null) byId[id]!.string('fileRef')!,
      };
}

// =============================================================================
// Old-style ASCII property list parser (with source offsets)
// =============================================================================

sealed class _PbxValue {
  const _PbxValue(this.start, this.end);

  /// Offset of the first character.
  final int start;

  /// Offset just past the last character.
  final int end;
}

final class _PbxString extends _PbxValue {
  const _PbxString(this.value, super.start, super.end);

  final String value;
}

final class _PbxArray extends _PbxValue {
  const _PbxArray(this.items, super.start, super.end);

  final List<_PbxValue> items;

  Iterable<String> get strings => items.whereType<_PbxString>().map(
        (item) => item.value,
      );
}

final class _PbxDict extends _PbxValue {
  _PbxDict(this.entries, super.start, super.end);

  final List<_PbxEntry> entries;

  late final Map<String, _PbxValue> _index = <String, _PbxValue>{
    for (final entry in entries) entry.key.value: entry.value,
  };

  _PbxValue? operator [](String key) => _index[key];

  String? string(String key) {
    final value = this[key];
    return value is _PbxString ? value.value : null;
  }

  _PbxArray? array(String key) {
    final value = this[key];
    return value is _PbxArray ? value : null;
  }

  _PbxDict? dict(String key) {
    final value = this[key];
    return value is _PbxDict ? value : null;
  }
}

final class _PbxEntry {
  const _PbxEntry(this.key, this.value, this.end);

  final _PbxString key;
  final _PbxValue value;
  final int end;

  int get start => key.start;
}

class _PbxParser {
  _PbxParser(this._src, this._name);

  final String _src;
  final String _name;
  int _pos = 0;

  _PbxDict parseDocument() {
    _skipTrivia();
    if (_pos >= _src.length || _src[_pos] != '{') {
      _fail('expected "{" at the start of the document');
    }
    final root = _parseDict();
    _skipTrivia();
    if (_pos < _src.length) {
      _fail('unexpected content after the root dictionary');
    }
    return root;
  }

  _PbxValue _parseValue() {
    _skipTrivia();
    if (_pos >= _src.length) {
      _fail('unexpected end of file');
    }
    final c = _src[_pos];
    if (c == '{') {
      return _parseDict();
    }
    if (c == '(') {
      return _parseArray();
    }
    return _parseString();
  }

  _PbxDict _parseDict() {
    final start = _pos;
    _pos++;
    final entries = <_PbxEntry>[];
    while (true) {
      _skipTrivia();
      if (_pos >= _src.length) {
        _fail('unterminated dictionary', start);
      }
      if (_src[_pos] == '}') {
        _pos++;
        return _PbxDict(entries, start, _pos);
      }
      final key = _parseString();
      _skipTrivia();
      _expect('=');
      final value = _parseValue();
      _skipTrivia();
      _expect(';');
      entries.add(_PbxEntry(key, value, _pos));
    }
  }

  _PbxArray _parseArray() {
    final start = _pos;
    _pos++;
    final items = <_PbxValue>[];
    while (true) {
      _skipTrivia();
      if (_pos >= _src.length) {
        _fail('unterminated list', start);
      }
      if (_src[_pos] == ')') {
        _pos++;
        return _PbxArray(items, start, _pos);
      }
      items.add(_parseValue());
      _skipTrivia();
      if (_pos < _src.length && _src[_pos] == ',') {
        _pos++;
      } else if (_pos >= _src.length || _src[_pos] != ')') {
        _fail('expected "," or ")" in list');
      }
    }
  }

  _PbxString _parseString() {
    if (_pos >= _src.length) {
      _fail('unexpected end of file, expected a string');
    }
    final start = _pos;
    if (_src[_pos] == '"') {
      _pos++;
      final buffer = StringBuffer();
      while (_pos < _src.length) {
        final c = _src[_pos];
        if (c == '"') {
          _pos++;
          return _PbxString(buffer.toString(), start, _pos);
        }
        if (c == r'\') {
          if (_pos + 1 >= _src.length) {
            break;
          }
          final next = _src[_pos + 1];
          switch (next) {
            case 'n':
              buffer.write('\n');
              _pos += 2;
            case 't':
              buffer.write('\t');
              _pos += 2;
            case 'r':
              buffer.write('\r');
              _pos += 2;
            case 'U' || 'u':
              final hex = _pos + 6 <= _src.length
                  ? _src.substring(_pos + 2, _pos + 6)
                  : '';
              final code = int.tryParse(hex, radix: 16);
              if (hex.length == 4 && code != null) {
                buffer.writeCharCode(code);
                _pos += 6;
              } else {
                buffer.write(next);
                _pos += 2;
              }
            default:
              buffer.write(next);
              _pos += 2;
          }
          continue;
        }
        buffer.write(c);
        _pos++;
      }
      _fail('unterminated quoted string', start);
    }

    while (_pos < _src.length && _isBareChar(_pos)) {
      _pos++;
    }
    if (_pos == start) {
      _fail('unexpected character "${_src[_pos]}"');
    }
    return _PbxString(_src.substring(start, _pos), start, _pos);
  }

  bool _isBareChar(int index) {
    final c = _src.codeUnitAt(index);
    if (c <= 0x20) {
      return false;
    }
    if (c == 0x2F && index + 1 < _src.length) {
      final next = _src.codeUnitAt(index + 1);
      if (next == 0x2A || next == 0x2F) {
        return false; // start of a comment
      }
    }
    return !'{}()=;,"<>'.contains(String.fromCharCode(c));
  }

  void _skipTrivia() {
    while (_pos < _src.length) {
      final c = _src.codeUnitAt(_pos);
      if (c == 0x20 ||
          c == 0x09 ||
          c == 0x0A ||
          c == 0x0D ||
          c == 0x0B ||
          c == 0x0C) {
        _pos++;
        continue;
      }
      if (c == 0x2F && _pos + 1 < _src.length) {
        final next = _src.codeUnitAt(_pos + 1);
        if (next == 0x2F) {
          final end = _src.indexOf('\n', _pos);
          _pos = end < 0 ? _src.length : end + 1;
          continue;
        }
        if (next == 0x2A) {
          final end = _src.indexOf('*/', _pos + 2);
          if (end < 0) {
            _fail('unterminated comment');
          }
          _pos = end + 2;
          continue;
        }
      }
      return;
    }
  }

  void _expect(String char) {
    if (_pos >= _src.length || _src[_pos] != char) {
      _fail('expected "$char"');
    }
    _pos++;
  }

  Never _fail(String message, [int? offset]) {
    final at = offset ?? _pos;
    var line = 1;
    final limit = at > _src.length ? _src.length : at;
    for (var i = 0; i < limit; i++) {
      if (_src.codeUnitAt(i) == 0x0A) {
        line++;
      }
    }
    throw LocalizerParseException(
      '$_name: $message (line $line).',
      path: _name,
      hint: 'The project file could not be parsed, so it was not modified. '
          'Open the project in Xcode to repair it, or use --skip-pbxproj.',
    );
  }
}
