import 'dart:async';

import 'package:flutter/material.dart';

import '../courses/course_model.dart';
import 'manual_time.dart';
import 'manual_time_controller.dart';

class ManualTimePage extends StatefulWidget {
  const ManualTimePage({
    super.key,
    required this.course,
    required this.controller,
  });
  final CourseClass course;
  final ManualTimeController controller;
  @override
  State<ManualTimePage> createState() => _ManualTimePageState();
}

class _ManualTimePageState extends State<ManualTimePage> {
  ManualTimeController get _times => widget.controller;
  bool _discarding = false, _closing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_times.load());
  }

  @override
  void dispose() {
    _times.dispose();
    super.dispose();
  }

  Future<void> _edit([ManualClassTime? old]) async {
    final values = await showDialog<List<ManualClassTime>>(
      context: context,
      builder: (_) => _TimeEditor(old: old),
    );
    if (!mounted || values == null) return;
    _times.replace(old: old, additions: values);
  }

  Future<void> _back() async {
    if (_times.saving || _closing) return;
    _closing = true;
    final leave =
        !_times.dirty ||
        await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('放弃未保存的时间？'),
                content: const Text('返回后将保留上次已保存的安排。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('继续编辑'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('放弃更改'),
                  ),
                ],
              ),
            ) ==
            true;
    _closing = false;
    if (!mounted || !leave) return;
    setState(() => _discarding = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, _times.blocked);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _times,
    builder: (context, _) => PopScope(
      canPop:
          _discarding || (!_times.dirty && !_times.saving && !_times.blocked),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('手工上课时间'),
          leading: BackButton(onPressed: _back),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(22),
                  children: [
                    if (!_times.blocked) ...[
                      Text(
                        widget.course.name,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      if (widget.course.className.isNotEmpty)
                        Text(widget.course.className),
                    ],
                    const SizedBox(height: 12),
                    const Text(
                      '北京时间（UTC+8）· 手工录入\n仅保存在这台设备，尚未同步云端／启用监听。',
                      style: TextStyle(height: 1.7),
                    ),
                    const SizedBox(height: 12),
                    if (_times.loading) const LinearProgressIndicator(),
                    if (_times.error case final error?)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(error, key: const ValueKey('time-error')),
                            if (!_times.blocked && !_times.saving)
                              TextButton(
                                onPressed: _times.dirty
                                    ? _times.save
                                    : _times.load,
                                child: const Text('重试'),
                              ),
                          ],
                        ),
                      ),
                    OutlinedButton.icon(
                      key: const ValueKey('add-class-time'),
                      onPressed: _times.canEdit ? () => _edit() : null,
                      icon: const Icon(Icons.add),
                      label: const Text('添加课次'),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '共 ${_times.entries.length} 次手工安排',
                      key: const ValueKey('class-time-count'),
                    ),
                    if (_times.dirty) const Text('有未保存的更改，请核对下方实际课次后保存。'),
                    if (_times.ready && _times.entries.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text('尚未录入上课时间。'),
                      ),
                    ..._times.entries.map(
                      (e) => Card(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(e.label),
                              Wrap(
                                alignment: WrapAlignment.end,
                                children: [
                                  TextButton(
                                    key: ValueKey('edit-time-${e.key}'),
                                    onPressed: _times.canEdit
                                        ? () => _edit(e)
                                        : null,
                                    child: const Text('修改这次'),
                                  ),
                                  TextButton(
                                    key: ValueKey('delete-time-${e.key}'),
                                    onPressed: _times.canEdit
                                        ? () => _times.remove(e)
                                        : null,
                                    child: const Text('删除这次'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '每周批量生成的是具体日期；以后修改或删除仅影响所点的这一次。每班最多 200 次，同班同日时段不可重叠；不同班级间的冲突暂需自行核对。取消选课不会删除这些本机时间。',
                        style: TextStyle(fontSize: 12, height: 1.7),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('save-class-times'),
                      onPressed: _times.canSave ? _times.save : null,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(
                        _times.saving
                            ? '正在保存'
                            : _times.ready && !_times.dirty
                            ? '本机时间已保存'
                            : '保存本机时间',
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '手工时间 · 尚未启用监听',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _TimeEditor extends StatefulWidget {
  const _TimeEditor({this.old});
  final ManualClassTime? old;
  @override
  State<_TimeEditor> createState() => _TimeEditorState();
}

class _TimeEditorState extends State<_TimeEditor> {
  late String _date, _until;
  late int _start, _end;
  bool _weekly = false;
  List<ManualClassTime>? _preview;
  String? _error;

  @override
  void initState() {
    super.initState();
    _date =
        widget.old?.date ??
        formatClassDate(DateTime.now().toUtc().add(const Duration(hours: 8)));
    _until = formatClassDate(
      parseClassDate(_date).add(const Duration(days: 28)),
    );
    _start = widget.old?.start ?? 8 * 60;
    _end = widget.old?.end ?? 9 * 60 + 40;
  }

  void _change(VoidCallback action) => setState(() {
    action();
    _preview = null;
    _error = null;
  });

  Future<void> _pickDate(bool until) async {
    final value = parseClassDate(until ? _until : _date);
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(value.year, value.month, value.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      helpText: until ? '选择每周重复的截止日期' : '选择上课日期',
      cancelText: '取消',
      confirmText: '确认',
    );
    if (!mounted || picked == null) return;
    _change(() {
      if (until) {
        _until = formatClassDate(picked);
      } else {
        _date = formatClassDate(picked);
      }
    });
  }

  Future<void> _pickTime(bool end) async {
    final minute = end ? _end : _start;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
      helpText: end ? '结束时间（北京时间）' : '开始时间（北京时间）',
      cancelText: '取消',
      confirmText: '确认',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (!mounted || picked == null) return;
    _change(() {
      final value = picked.hour * 60 + picked.minute;
      if (end) {
        _end = value;
      } else {
        _start = value;
      }
    });
  }

  void _buildPreview() {
    try {
      final values = ManualClassTime.generate(
        firstDate: _date,
        start: _start,
        end: _end,
        weeklyUntil: _weekly ? _until : null,
      );
      setState(() {
        _preview = values;
        _error = null;
      });
    } on TimeInputFailure catch (e) {
      setState(() {
        _preview = null;
        _error = timeInputMessage(e.issue);
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.old == null ? '添加上课时间' : '修改这次上课时间'),
    content: SizedBox(
      width: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('北京时间（UTC+8），同日结束。'),
          const SizedBox(height: 12),
          OutlinedButton(
            key: const ValueKey('time-date'),
            onPressed: () => _pickDate(false),
            child: Text('上课日期  $_date'),
          ),
          OutlinedButton(
            key: const ValueKey('time-start'),
            onPressed: () => _pickTime(false),
            child: Text('开始  ${formatClassMinute(_start)}'),
          ),
          OutlinedButton(
            key: const ValueKey('time-end'),
            onPressed: () => _pickTime(true),
            child: Text('结束  ${formatClassMinute(_end)}'),
          ),
          if (widget.old == null)
            SwitchListTile(
              key: const ValueKey('time-weekly'),
              contentPadding: EdgeInsets.zero,
              title: const Text('每周重复'),
              subtitle: const Text('与首次日期同一星期几，截止日包含在范围内。'),
              value: _weekly,
              onChanged: (value) => _change(() => _weekly = value),
            ),
          if (_weekly)
            OutlinedButton(
              key: const ValueKey('time-until'),
              onPressed: () => _pickDate(true),
              child: Text('重复截止  $_until'),
            ),
          if (_error != null)
            Text(_error!, key: const ValueKey('time-input-error')),
          TextButton(
            key: const ValueKey('preview-class-times'),
            onPressed: _buildPreview,
            child: const Text('预览实际课次'),
          ),
          if (_preview case final values?) ...[
            Text(
              '将${widget.old == null ? '添加' : '替换为'} ${values.length} 次课，核对后确认：',
            ),
            const SizedBox(height: 8),
            Text(
              values.map((e) => e.label).join('\n'),
              key: const ValueKey('class-time-preview'),
              style: const TextStyle(height: 1.7),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('confirm-class-times'),
        onPressed: _preview == null
            ? null
            : () => Navigator.pop(context, _preview),
        child: const Text('加入待保存安排'),
      ),
    ],
  );
}
