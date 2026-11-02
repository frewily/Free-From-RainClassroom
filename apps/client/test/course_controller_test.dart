import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rainclient/courses/course_controller.dart';
import 'package:rainclient/courses/course_model.dart';

import 'auth_fakes.dart';
import 'course_fakes.dart';

void main() {
  late MemoryStore sessions;
  late FakeCourseGateway gateway;
  late CourseMemoryStorage storage;
  late CourseController controller;
  setUp(() {
    sessions = MemoryStore('synthetic-session');
    gateway = FakeCourseGateway();
    storage = CourseMemoryStorage();
    controller = CourseController(
      sessions: sessions,
      gateway: gateway,
      selections: storage.store,
    );
  });
  tearDown(() => controller.dispose());

  test('selection restores by account and preserves ids absent from the current list', () async {
    storage.seed('account-a', ['one', 'old']);
    await controller.load();
    expect(controller.selected, {'one', 'old'});
    controller.toggle('two', true);
    await controller.save();
    expect(storage.record(gateway.owner).value!['selected'], [
      'old',
      'one',
      'two',
    ]);
    expect(controller.dirty, isFalse);
  });

  test(
    'archive switching keeps unsaved choices and never saves by itself',
    () async {
      await controller.load();
      controller.toggle('one', true);
      await controller.load(showArchived: true);
      controller.toggle('old', true);
      expect(controller.selected, {'one', 'old'});
      expect(storage.record(gateway.owner).value, isNull);
    },
  );

  test('partial reads cannot change or overwrite a saved selection', () async {
    storage.seed('account-a', ['one']);
    gateway.complete = false;
    await controller.load();
    controller.toggle('two', true);
    controller.clearSelection();
    await controller.save();
    expect(controller.selected, {'one'});
    expect(storage.record(gateway.owner).value!['selected'], ['one']);
    expect(controller.canEdit, isFalse);
  });

  test(
    'network failure retains the last good listing and unsaved selection',
    () async {
      await controller.load();
      controller.toggle('two', true);
      gateway.error = const CourseFailure(CourseIssue.network);
      await controller.load();
      expect(controller.failure!.issue, CourseIssue.network);
      expect(controller.listing!.classes.length, 2);
      expect(controller.selected, {'two'});
      expect(controller.dirty, isTrue);
    },
  );

  test('storage failure never pretends a selection was saved', () async {
    await controller.load();
    controller.toggle('one', true);
    storage.record(gateway.owner).failWrite = true;
    await controller.save();
    expect(controller.failure!.issue, CourseIssue.storage);
    expect(controller.selected, {'one'});
    expect(controller.dirty, isTrue);
  });

  test('changing the saved session while a list is in flight discards the old account', () async {
    final gate = Completer<CourseListing>();
    gateway.listGate = gate;
    final load = controller.load();
    await gateway.listStarted.future;
    sessions.value = 'new-synthetic-session';
    gate.complete(courseList());
    await load;
    expect(controller.needsLogin, isTrue);
    expect(controller.account, isNull);
    expect(controller.listing, isNull);
    expect(controller.selected, isEmpty);
  });

  test('an older completion cannot overwrite a newer account', () async {
    final gate = Completer<CourseListing>();
    gateway.listGate = gate;
    final first = controller.load();
    await gateway.listStarted.future;
    gateway.listGate = null;
    gateway.owner = const CourseAccount('account-b');
    sessions.value = 'session-for-b';
    storage.seed('account-b', ['two']);
    await controller.load();
    gate.complete(courseList(archived: true));
    await first;
    expect(controller.account!.id, 'account-b');
    expect(controller.selected, {'two'});
    expect(controller.listing!.archived, isFalse);
  });

  test(
    'session rotation during a failed refresh also hides the old account',
    () async {
      await controller.load();
      final gate = Completer<CourseListing>();
      gateway.listGate = gate;
      gateway.listStarted = Completer<void>();
      final refresh = controller.load();
      await gateway.listStarted.future;
      sessions.value = 'session-for-another-account';
      gate.completeError(const CourseFailure(CourseIssue.network));
      await refresh;
      expect(controller.needsLogin, isTrue);
      expect(controller.account, isNull);
      expect(controller.listing, isNull);
    },
  );

  test('save rechecks local identity and cannot write old choices to another account', () async {
    await controller.load();
    controller.toggle('one', true);
    sessions.value = 'another-session';
    await controller.save();
    expect(controller.needsLogin, isTrue);
    expect(storage.record(const CourseAccount('account-a')).value, isNull);
    expect(storage.record(const CourseAccount('account-b')).value, isNull);
  });

  test('an in-flight save stays in its own account namespace after session rotation', () async {
    await controller.load();
    controller.toggle('one', true);
    final record = storage.record(gateway.owner);
    record.writeGate = Completer<void>();
    final save = controller.save();
    await record.writeStarted.future;
    sessions.value = 'another-session';
    record.writeGate!.complete();
    await save;
    expect(controller.needsLogin, isTrue);
    expect(record.value!['accountId'], 'account-a');
    expect(storage.record(const CourseAccount('account-b')).value, isNull);
  });

  test('corrupt or foreign saved data is not overwritten on read', () async {
    final record = storage.record(gateway.owner);
    record.value = {
      'version': 1,
      'origin': courseOrigin,
      'accountId': 'other-account',
      'selected': ['one'],
    };
    await controller.load();
    expect(controller.failure!.issue, CourseIssue.storage);
    expect(controller.canSave, isFalse);
    expect(record.value!['accountId'], 'other-account');
  });

  test(
    'logout hides previous data while preserving encrypted choices',
    () async {
      storage.seed('account-a', ['one']);
      await controller.load();
      sessions.value = null;
      await controller.load();
      expect(controller.needsLogin, isTrue);
      expect(controller.listing, isNull);
      expect(storage.record(gateway.owner).value!['selected'], ['one']);
    },
  );

  test(
    'oversized selections are refused before replacing the previous record',
    () async {
      const owner = CourseAccount('account-a');
      storage.seed(owner.id, ['one']);
      final ids = Set<String>.from(
        List.generate(1000, (i) => '${'a' * 120}$i'),
      );
      await expectLater(
        storage.store.write(owner, ids),
        throwsA(isA<CourseFailure>()),
      );
      expect(storage.record(owner).value!['selected'], ['one']);
    },
  );
}
