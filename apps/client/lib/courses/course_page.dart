import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/session_store.dart';
import 'course_client.dart';
import 'course_controller.dart';
import 'course_model.dart';
import 'course_store.dart';

class CoursePage extends StatefulWidget {
  const CoursePage({super.key, this.controller, this.sessions});
  final CourseController? controller;
  final SessionStore? sessions;
  @override
  State<CoursePage> createState() => _CoursePageState();
}

class _CoursePageState extends State<CoursePage> {
  late final CourseController _courses;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _courses =
        widget.controller ??
        CourseController(
          sessions: widget.sessions ?? SecureSessionStore(),
          gateway: CourseClient(),
          selections: CourseSelectionStore(),
        );
    unawaited(_courses.load());
  }

  @override
  void dispose() {
    if (widget.controller == null) _courses.dispose();
    super.dispose();
  }

  String _failureMessage(CourseFailure failure) => switch (failure.issue) {
    CourseIssue.login => '雨课堂登录已失效或未登录，请返回登录页重新连接。',
    CourseIssue.changed => '本机登录已变化，请返回登录页后重新打开课程选择。',
    CourseIssue.network => '暂时无法同步课程。已有选择仍保留，请检查网络后重试。',
    CourseIssue.storage => '暂时无法读取或保存本机选择，请重试。',
    CourseIssue.response => '课程信息暂时无法完整识别，已有选择未被覆盖。请重试或保留问题阶段供排查。',
  };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _courses,
    builder: (context, _) {
      final listing = _courses.listing;
      final all = listing?.classes ?? <CourseClass>[];
      final query = _query.trim().toLowerCase();
      final visible = all
          .where(
            (c) => '${c.name} ${c.className} ${c.teacher}'
                .toLowerCase()
                .contains(query),
          )
          .toList();
      final selectedHere = all
          .where((c) => _courses.selected.contains(c.id))
          .length;
      final hiddenSelected = _courses.selected.length - selectedHere;
      return PopScope(
        canPop: !_courses.saving,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('选择课程班级'),
            actions: [
              IconButton(
                key: const ValueKey('refresh-courses'),
                tooltip: '同步课程',
                onPressed: _courses.loading || _courses.saving
                    ? null
                    : () => _courses.load(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(22, 16, 22, 24),
                    children: [
                      const Text(
                        '选择你关注的课',
                        style: TextStyle(
                          fontFamily: 'serif',
                          fontSize: 30,
                          color: Color(0xff173b3c),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '选择按雨课堂账号保存在这台设备。\n尚未配置监听时间，也尚未启用监听。',
                        style: TextStyle(height: 1.7, color: Color(0xff61726b)),
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('查看归档班级'),
                        subtitle: const Text('未归档和归档分开读取，切换不会清空选择。'),
                        value: _courses.archived,
                        onChanged: _courses.loading || _courses.saving
                            ? null
                            : (value) => _courses.load(showArchived: value),
                      ),
                      if (_courses.loading) ...[
                        const LinearProgressIndicator(),
                        const SizedBox(height: 12),
                        const Text(
                          '正在读取课程班级…',
                          key: ValueKey('courses-loading'),
                        ),
                      ],
                      if (_courses.failure case final failure?) ...[
                        Container(
                          margin: const EdgeInsets.symmetric(vertical: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xfff4e8de),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _failureMessage(failure),
                                key: const ValueKey('course-error'),
                                style: const TextStyle(height: 1.6),
                              ),
                              if (failure.stage.isNotEmpty)
                                Text(
                                  '读取阶段：${failure.stage}；HTTP ${failure.httpStatus ?? '未返回'}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              if (listing != null) const Text('以下为上次成功读取的结果。'),
                              TextButton(
                                onPressed: _courses.loading || _courses.saving
                                    ? null
                                    : _courses.needsLogin
                                    ? () => Navigator.pop(context, true)
                                    : () => _courses.load(),
                                child: Text(
                                  _courses.needsLogin ? '返回登录页' : '重试读取',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (listing != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          '已读取 ${all.length} 个${listing.archived ? '归档' : '未归档'}班级',
                          key: const ValueKey('course-count'),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (!listing.complete)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 10),
                            child: Text(
                              '列表尚未完整加载，暂不更新选择。请重试同步。',
                              key: ValueKey('courses-incomplete'),
                            ),
                          ),
                        if (hiddenSelected > 0)
                          Text(
                            '另有 $hiddenSelected 个已选班级未在当前列表中显示，选择仍保留。',
                            style: const TextStyle(
                              height: 1.6,
                              color: Color(0xff61726b),
                            ),
                          ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const ValueKey('course-search'),
                          decoration: const InputDecoration(
                            hintText: '搜索课程、班级或教师',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (value) => setState(() => _query = value),
                        ),
                        const SizedBox(height: 12),
                        if (all.isEmpty && listing.complete)
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Text('当前列表没有课程班级。'),
                          ),
                        if (all.isNotEmpty && visible.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Text('没有符合搜索条件的班级。'),
                          ),
                        ...visible.map(
                          (course) => Card(
                            color: const Color(0xfffdfdf8),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: const BorderSide(color: Color(0xffd6ded6)),
                            ),
                            child: CheckboxListTile(
                              key: ValueKey('course-${course.id}'),
                              controlAffinity: ListTileControlAffinity.leading,
                              isThreeLine: false,
                              value: _courses.selected.contains(course.id),
                              onChanged: _courses.canEdit
                                  ? (value) => _courses.toggle(
                                      course.id,
                                      value == true,
                                    )
                                  : null,
                              title: Text(
                                course.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  [
                                    course.className.isEmpty
                                        ? '班级名未提供'
                                        : course.className,
                                    if (course.teacher.isNotEmpty)
                                      course.teacher,
                                    course.term == null
                                        ? '学期标记未提供'
                                        : '学期标记 ${course.term}',
                                    if (course.role == 6) '旁听',
                                  ].join('\n'),
                                  style: const TextStyle(height: 1.5),
                                ),
                              ),
                            ),
                          ),
                        ),
                        ExpansionTile(
                          title: const Text('核对读取结果'),
                          children: [
                            ListTile(
                              dense: true,
                              title: Text(
                                '当前显示 ${all.length} 个班级；'
                                '${all.where((c) => c.courseId != null).length} 个带课程标识；'
                                '${all.where((c) => c.term != null).length} 个带学期标记。',
                              ),
                            ),
                            const ListTile(
                              dense: true,
                              title: Text('同名课程按班级分别保存。未提供的学期不作推算；这里只读取长江雨课堂。'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Color(0xffd6ded6))),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '已选择 ${_courses.selected.length} 个班级',
                              key: const ValueKey('selected-course-count'),
                            ),
                          ),
                          TextButton(
                            key: const ValueKey('clear-course-selection'),
                            onPressed:
                                _courses.canEdit && _courses.selected.isNotEmpty
                                ? _courses.clearSelection
                                : null,
                            child: const Text('清空选择'),
                          ),
                        ],
                      ),
                      FilledButton.icon(
                        key: const ValueKey('save-course-selection'),
                        onPressed: _courses.canSave ? _courses.save : null,
                        icon: _courses.saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check),
                        label: Text(
                          _courses.saving
                              ? '正在保存'
                              : _courses.dirty || _courses.account == null
                              ? '保存选择'
                              : '选择已保存',
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '本机选择 · 尚未配置时间／启用监听',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xff61726b),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
