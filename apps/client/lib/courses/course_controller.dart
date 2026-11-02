import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auth/session_store.dart';
import 'course_client.dart';
import 'course_model.dart';
import 'course_store.dart';

class CourseController extends ChangeNotifier {
  CourseController({
    required this._sessions,
    required this._gateway,
    required this._selections,
    this.ioTimeout = const Duration(seconds: 8),
  });
  final SessionStore _sessions;
  final CourseGateway _gateway;
  final CourseSelectionStore _selections;
  final Duration ioTimeout;
  CourseAccount? account;
  CourseListing? listing;
  CourseFailure? failure;
  bool loading = false, saving = false, archived = false;
  DateTime? loadedAt;
  String? _session;
  Set<String> _selected = {}, _saved = {};
  bool _disposed = false;
  int _generation = 0;

  Set<String> get selected => Set.unmodifiable(_selected);
  bool get dirty => !setEquals(_selected, _saved);
  bool get needsLogin =>
      failure?.issue == CourseIssue.login ||
      failure?.issue == CourseIssue.changed;
  bool get canEdit =>
      !loading && !saving && !needsLogin && listing?.complete == true;
  bool get canSave => canEdit && account != null && dirty;
  bool _current(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _clear() {
    account = null;
    listing = null;
    loadedAt = null;
    _selected = {};
    _saved = {};
  }

  Future<void> _checkSession(String session) async {
    final current = await _sessions.read().timeout(ioTimeout);
    if (current != session) throw const CourseFailure(CourseIssue.changed);
  }

  Future<void> _recordFailure(
    CourseFailure error,
    int generation,
    String? session, {
    bool hideOnStorage = false,
  }) async {
    if (!_current(generation)) return;
    var safeError = error;
    if (session != null &&
        error.issue != CourseIssue.login &&
        error.issue != CourseIssue.changed) {
      try {
        await _checkSession(session);
      } on CourseFailure catch (changed) {
        safeError = changed;
      } on Object {
        safeError = const CourseFailure(CourseIssue.storage);
      }
    }
    if (!_current(generation)) return;
    failure = safeError;
    if (needsLogin ||
        (hideOnStorage && safeError.issue == CourseIssue.storage)) {
      _clear();
      _session = null;
    }
  }

  Future<void> load({bool? showArchived}) async {
    if (_disposed || saving) return;
    final generation = ++_generation;
    _gateway.cancel();
    archived = showArchived ?? archived;
    if (listing?.archived != archived) {
      listing = null;
      loadedAt = null;
    }
    loading = true;
    failure = null;
    _notify();
    String? attemptedSession;
    try {
      final session = await _sessions.read().timeout(ioTimeout);
      attemptedSession = session;
      if (!_current(generation)) return;
      if (session == null) throw const CourseFailure(CourseIssue.login);
      if (session != _session) {
        _clear();
        _session = session;
        _notify();
      }
      final owner = await _gateway.identify(session);
      if (!_current(generation)) return;
      await _checkSession(session);
      if (!_current(generation)) return;
      if (account?.id != owner.id) {
        _clear();
        final saved = await _selections.read(owner).timeout(ioTimeout);
        if (!_current(generation)) return;
        _selected = {...saved};
        _saved = {...saved};
        account = owner;
      }
      final result = await _gateway.list(session, owner, archived: archived);
      if (!_current(generation)) return;
      await _checkSession(session);
      if (!_current(generation)) return;
      listing = result;
      loadedAt = DateTime.now();
    } on CourseFailure catch (error) {
      await _recordFailure(
        error,
        generation,
        attemptedSession,
        hideOnStorage: true,
      );
    } on Object {
      await _recordFailure(
        const CourseFailure(CourseIssue.storage),
        generation,
        attemptedSession,
        hideOnStorage: true,
      );
    } finally {
      if (_current(generation)) {
        loading = false;
        _notify();
      }
    }
  }

  void toggle(String id, bool selected) {
    if (!canEdit || !listing!.classes.any((c) => c.id == id)) return;
    if (selected) {
      _selected.add(id);
    } else {
      _selected.remove(id);
    }
    _notify();
  }

  void clearSelection() {
    if (!canEdit) return;
    _selected = {};
    _notify();
  }

  Future<void> save() async {
    if (!canSave || _session == null) return;
    final generation = ++_generation;
    final owner = account!, session = _session!, selected = {..._selected};
    saving = true;
    failure = null;
    _notify();
    try {
      await _checkSession(session);
      if (!_current(generation)) return;
      await _selections.write(owner, selected).timeout(ioTimeout);
      if (!_current(generation)) return;
      await _checkSession(session);
      if (!_current(generation)) return;
      _saved = selected;
    } on CourseFailure catch (error) {
      await _recordFailure(error, generation, session);
    } on Object {
      await _recordFailure(
        const CourseFailure(CourseIssue.storage),
        generation,
        session,
      );
    } finally {
      if (_current(generation)) {
        saving = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _gateway.cancel();
    super.dispose();
  }
}
