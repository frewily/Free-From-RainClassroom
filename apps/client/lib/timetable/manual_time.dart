const manualTimeZone = 'Asia/Shanghai';
const maxClassTimes = 200;

enum TimeInputIssue { date, clock, range, overlap, limit }

class TimeInputFailure implements Exception {
  const TimeInputFailure(this.issue);
  final TimeInputIssue issue;
}

String timeInputMessage(TimeInputIssue issue) => switch (issue) {
  TimeInputIssue.date => '请选择 2000 至 2100 年内的有效日期。',
  TimeInputIssue.clock => '结束时间须晚于开始时间；本轮仅支持同日时段。',
  TimeInputIssue.range => '重复结束日期不能早于首次日期，范围最多 366 天。',
  TimeInputIssue.overlap => '同一班级在该日期已有重复或重叠时段，请先调整。',
  TimeInputIssue.limit => '每个班级最多保存 200 次课，请缩小范围或删除旧安排。',
};

DateTime parseClassDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const TimeInputFailure(TimeInputIssue.date);
  }
  final parts = value.split('-').map(int.parse).toList();
  final date = DateTime.utc(parts[0], parts[1], parts[2]);
  if (parts[0] < 2000 || parts[0] > 2100 || formatClassDate(date) != value) {
    throw const TimeInputFailure(TimeInputIssue.date);
  }
  return date;
}

String formatClassDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String formatClassMinute(int value) =>
    '${(value ~/ 60).toString().padLeft(2, '0')}:'
    '${(value % 60).toString().padLeft(2, '0')}';

class ManualClassTime {
  ManualClassTime({
    required this.date,
    required this.start,
    required this.end,
  }) {
    parseClassDate(date);
    if (start < 0 || start >= 1440 || end <= start || end >= 1440) {
      throw const TimeInputFailure(TimeInputIssue.clock);
    }
  }
  final String date;
  final int start, end;
  String get key => '$date/$start/$end';
  String get label =>
      '$date  ${formatClassMinute(start)}–${formatClassMinute(end)}';
  Map<String, dynamic> toJson() => {'date': date, 'start': start, 'end': end};

  factory ManualClassTime.fromJson(Object? value) {
    if (value is! Map ||
        value['date'] is! String ||
        value['start'] is! int ||
        value['end'] is! int) {
      throw const TimeInputFailure(TimeInputIssue.clock);
    }
    return ManualClassTime(
      date: value['date'],
      start: value['start'],
      end: value['end'],
    );
  }

  static List<ManualClassTime> generate({
    required String firstDate,
    required int start,
    required int end,
    String? weeklyUntil,
  }) {
    final first = parseClassDate(firstDate);
    final last = weeklyUntil == null ? first : parseClassDate(weeklyUntil);
    final span = last.difference(first).inDays;
    if (span < 0 || span > 365) {
      throw const TimeInputFailure(TimeInputIssue.range);
    }
    return [
      for (var offset = 0; offset <= span; offset += 7)
        ManualClassTime(
          date: formatClassDate(first.add(Duration(days: offset))),
          start: start,
          end: end,
        ),
    ];
  }
}

List<ManualClassTime> validateClassTimes(Iterable<ManualClassTime> values) {
  final sorted = values.toList();
  if (sorted.length > maxClassTimes) {
    throw const TimeInputFailure(TimeInputIssue.limit);
  }
  sorted.sort((a, b) {
    final date = a.date.compareTo(b.date);
    return date == 0 ? a.start.compareTo(b.start) : date;
  });
  for (var i = 1; i < sorted.length; i++) {
    if (sorted[i].date == sorted[i - 1].date &&
        sorted[i].start < sorted[i - 1].end) {
      throw const TimeInputFailure(TimeInputIssue.overlap);
    }
  }
  return List.unmodifiable(sorted);
}
