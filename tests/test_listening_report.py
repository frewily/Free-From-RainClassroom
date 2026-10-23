import contextlib
import io
import os
import threading
import time
import unittest
from unittest import mock

from util.listening_report import ListeningReport


class ListeningReportTests(unittest.TestCase):
    def test_missing_configuration_does_not_construct_report_or_collect_logs(self):
        from util.listening_report import create_listening_report

        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch("util.listening_report.ListeningReport") as report_class:
            self.assertIsNone(create_listening_report("示例课", 1))
        report_class.assert_not_called()

    def test_report_construction_failure_is_isolated(self):
        from util.listening_report import create_listening_report

        with mock.patch("util.listening_report.email_is_configured", return_value=True), \
                mock.patch("util.listening_report.ListeningReport", side_effect=RuntimeError("private error")):
            self.assertIsNone(create_listening_report("示例课", 1))

    def test_failed_mail_thread_start_does_not_break_cleanup(self):
        from util.listening_report import report_call

        report = ListeningReport("示例课", 1, sender=mock.Mock())
        with mock.patch("util.listening_report.threading.Thread.start", side_effect=RuntimeError("private error")):
            self.assertIsNone(report_call(report, "mark_started"))
        report_call(report, "finish", "停止")

    def test_stalled_sender_does_not_hold_finish_or_process_alive(self):
        sending = threading.Event()
        release = threading.Event()
        messages = []

        def sender(**mail):
            sending.set()
            release.wait(2)
            messages.append(mail)

        report = ListeningReport("示例课", 1, sender=sender)
        with mock.patch("util.listening_report.MAIL_DRAIN_SECONDS", 0.03):
            report.mark_started()
            try:
                self.assertTrue(sending.wait(1))
                before = time.monotonic()
                report.finish("窗口结束")
                self.assertLess(time.monotonic() - before, 0.5)
                self.assertEqual([], messages)
                self.assertTrue(report._mail_worker.daemon)
            finally:
                release.set()
                report._mail_worker.join(timeout=1)
        self.assertEqual(2, len(messages))

    def test_stalled_processors_have_one_shared_drain_budget(self):
        release = threading.Event()
        workers = [threading.Thread(target=release.wait, args=(2,), daemon=True) for _ in range(2)]
        messages = []
        report = ListeningReport("示例课", 1, sender=lambda **mail: messages.append(mail))
        report.mark_started()
        record = report.begin_answer("q1", "单选题", "测试题", [])
        for worker in workers:
            worker.start()
            report.track_processor(worker)
        try:
            with mock.patch("util.listening_report.PROCESSOR_DRAIN_SECONDS", 0.03):
                before = time.monotonic()
                report.finish("窗口结束")
                self.assertLess(time.monotonic() - before, 0.5)
            self.assertTrue(all(worker.is_alive() for worker in workers))
            report.update_answer(record, status="late result")
        finally:
            release.set()
            for worker in workers:
                worker.join(timeout=1)
        self.assertIn("仍在处理", messages[-1]["attachment_text"])
        self.assertNotIn("late result", messages[-1]["attachment_text"])

    def test_never_connected_does_not_claim_started_or_ended(self):
        sender = mock.Mock()
        report = ListeningReport("示例课", 1, sender=sender)
        report.finish("连接失败")
        sender.assert_not_called()

    def test_two_ordered_emails_despite_reconnect_and_repeated_finish(self):
        messages = []
        report = ListeningReport("示例课", 1, sender=lambda **mail: messages.append(mail))
        report.mark_started()
        report.note_reconnect()
        report.mark_started()
        report.set_end_reason("教师下课")
        report.finish("主程序停止")
        report.finish("重复结束")
        self.assertEqual(2, len(messages))
        self.assertIn("已进入监听", messages[0]["subject"])
        self.assertIn("监听结束", messages[1]["subject"])
        self.assertIn("教师下课", messages[1]["content"])
        self.assertIn("重连次数：1", messages[1]["content"])
        self.assertIn("没有题目处理记录", messages[1]["attachment_text"])

    def test_start_email_does_not_block_callback_and_end_waits_for_it(self):
        sending = threading.Event()
        release = threading.Event()
        messages = []

        def sender(**mail):
            if "已进入监听" in mail["subject"]:
                sending.set()
                release.wait(2)
            messages.append(mail)

        report = ListeningReport("示例课", 1, sender=sender)
        report.mark_started()
        try:
            self.assertTrue(sending.wait(1))
            self.assertEqual([], messages)
        finally:
            release.set()
            report.finish("窗口结束")
        self.assertEqual(2, len(messages))
        self.assertIn("已进入监听", messages[0]["subject"])

    def test_private_log_contains_result_but_redacts_credentials(self):
        messages = []
        with mock.patch.dict(os.environ, {
            "SESSION": "private-session-value", "EMAIL_PASS": "private-mail-value",
            "GITHUB_REPOSITORY": "example/repo", "GITHUB_RUN_ID": "123",
        }):
            report = ListeningReport("示例课", 1, sensitive_values=("private-jwt-value",),
                                     sender=lambda **mail: messages.append(mail))
            report.mark_started()
            record = report.begin_answer("q1", "单选题", "test private-session-value", ["A", "B"])
            report.update_answer(record, result=["A", "private-jwt-value", "private-mail-value"],
                                 status="提交接口返回 HTTP 200（未核验评分）")
            report.finish("窗口结束")
        attachment = messages[-1]["attachment_text"]
        self.assertIn("q1", attachment)
        self.assertIn("HTTP 200", attachment)
        self.assertIn("/actions/runs/123", attachment)
        for private in ("private-session-value", "private-jwt-value", "private-mail-value"):
            self.assertNotIn(private, attachment)
        self.assertIn("[已隐藏]", attachment)

    def test_log_is_bounded_and_unfinished_work_is_explicit(self):
        messages = []
        with mock.patch("util.listening_report.MAX_ENTRIES", 1), \
                mock.patch("util.listening_report.MAX_FIELD_LENGTH", 20):
            report = ListeningReport("示例课", 1, sender=lambda **mail: messages.append(mail))
            report.mark_started()
            report.begin_answer("q1", "单选题", "x" * 50, [])
            self.assertIsNone(report.begin_answer("q2", "单选题", "omitted", []))
            report.finish("窗口结束")
        attachment = messages[-1]["attachment_text"]
        self.assertNotIn("x" * 21, attachment)
        self.assertIn("仍在处理", attachment)
        self.assertIn("1 条记录未保存", attachment)

    def test_sender_exception_does_not_escape_or_print_error_body(self):
        output = io.StringIO()
        sender = mock.Mock(side_effect=RuntimeError("private-value"))
        report = ListeningReport("示例课", 1, sender=sender)
        with contextlib.redirect_stdout(output):
            report.mark_started()
            report.finish("窗口结束")
        self.assertIn("RuntimeError", output.getvalue())
        self.assertNotIn("private-value", output.getvalue())
        self.assertEqual(2, sender.call_count)


if __name__ == "__main__":
    unittest.main()
