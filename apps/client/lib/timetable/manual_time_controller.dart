import 'dart:async';

import 'package:flutter/foundation.dart';

import '../courses/course_model.dart';
import 'manual_time.dart';
import 'manual_time_store.dart';

class ManualTimeController extends ChangeNotifier {
  ManualTimeController({
    required this.checkAccess,
    required this.store,
    this.timeout = const Duration(seconds: 8),
  });
  final Future<void> Function() checkAccess;
  final ManualTimeStore store;
  final Duration timeout;
  List<ManualClassTime> _entries = [], _saved = [];
  List<ManualClassTime> get entries => List.unmodifiable(_entries);
  bool loading = false, saving = false, ready = false, blocked = false;
  String? error;
  bool _disposed = false;
  int _generation = 0;
  bool get dirty => !listEquals(
    _entries.map((e) => e.key).toList(),
    _saved.map((e) => e.key).toList(),
  );
  bool get canEdit => ready && !blocked && !loading && !saving;
  bool get canSave => canEdit && dirty;
  bool _current(int n) => !_disposed && n == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _failure(Object failure, int generation) async {
    if (!_current(generation)) return;
    // Recheck access even after a failed storage operation, before showing data.
    try {
      await checkAccess().timeout(timeout);
    } on Object {
      if (!_current(generation)) return;
      blocked = true;
      ready = false;
      _entries = [];
      _saved = [];
      error = '本机登录或课程选择已变化，或暂时无法确认。请返回课程页重新打开。';
      return;
    }
    if (!_current(generation)) return;
    if (failure is CourseFailure) {
      blocked = true;
      ready = false;
      _entries = [];
      _saved = [];
      error = '本机登录或课程选择已变化，请返回课程页重新打开。';
    } else {
      error = '暂时无法读取或保存本机时间，已有记录未被主动清除。请重试。';
    }
  }

  Future<void> load() async {
    if (_disposed || loading || saving || dirty) return;
    final n = ++_generation;
    loading = true;
    ready = false;
    blocked = false;
    error = null;
    _notify();
    try {
      await checkAccess().timeout(timeout);
      if (!_current(n)) return;
      final saved = await store.read().timeout(timeout);
      await checkAccess().timeout(timeout);
      if (!_current(n)) return;
      _entries = saved;
      _saved = saved;
      ready = true;
    } on Object catch (failure) {
      await _failure(failure, n);
    } finally {
      if (_current(n)) {
        loading = false;
        _notify();
      }
    }
  }

  bool replace({
    ManualClassTime? old,
    required List<ManualClassTime> additions,
  }) {
    if (!canEdit) return false;
    try {
      _entries = validateClassTimes([
        ..._entries.where((e) => e.key != old?.key),
        ...additions,
      ]);
      error = null;
      _notify();
      return true;
    } on TimeInputFailure catch (failure) {
      error = timeInputMessage(failure.issue);
      _notify();
      return false;
    }
  }

  void remove(ManualClassTime entry) {
    if (!canEdit) return;
    _entries = _entries.where((e) => e.key != entry.key).toList();
    error = null;
    _notify();
  }

  Future<void> save() async {
    if (!canSave) return;
    final n = ++_generation, draft = List<ManualClassTime>.of(_entries);
    saving = true;
    error = null;
    _notify();
    try {
      await checkAccess().timeout(timeout);
      if (!_current(n)) return;
      await store.write(draft).timeout(timeout);
      await checkAccess().timeout(timeout);
      if (!_current(n)) return;
      _saved = draft;
    } on Object catch (failure) {
      await _failure(failure, n);
    } finally {
      if (_current(n)) {
        saving = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
