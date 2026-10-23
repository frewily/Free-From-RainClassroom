import contextlib
import io
import os
import smtplib
import unittest
from unittest import mock

from util.notice import email_notice, send_email


SETTINGS = {
    "EMAIL_HOST": "smtp.example.invalid", "EMAIL_USER": "sender@example.invalid",
    "EMAIL_PASS": "fake-test-authorization", "TO_EMAIL": "recipient@example.invalid",
}


class EmailNoticeTests(unittest.TestCase):
    def test_legacy_exam_notification_remains_disabled(self):
        with mock.patch.dict(os.environ, SETTINGS, clear=True), \
                mock.patch("util.notice.smtplib.SMTP_SSL") as smtp:
            self.assertFalse(email_notice("考试提醒", "legacy"))
        smtp.assert_not_called()

    def test_unconfigured_mail_is_disabled_without_smtp(self):
        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch("util.notice.smtplib.SMTP_SSL") as smtp:
            self.assertFalse(send_email("subject", "body"))
        smtp.assert_not_called()

    def test_incomplete_configuration_skips_without_exposing_value(self):
        output = io.StringIO()
        with mock.patch.dict(os.environ, {"EMAIL_PASS": "private-test-password"}, clear=True), \
                mock.patch("util.notice.smtplib.SMTP_SSL") as smtp, \
                contextlib.redirect_stdout(output):
            self.assertFalse(send_email("subject", "body"))
        smtp.assert_not_called()
        self.assertNotIn("private-test-password", output.getvalue())

    def test_ssl_sends_unicode_body_and_text_attachment(self):
        with mock.patch.dict(os.environ, SETTINGS, clear=True), \
                mock.patch("util.notice.smtplib.SMTP_SSL") as smtp:
            self.assertTrue(send_email("监听结束", "课程：示例课", attachment_text="题目：测试\n结果：A"))
        smtp.assert_called_once_with(SETTINGS["EMAIL_HOST"], 465, timeout=10, context=mock.ANY)
        server = smtp.return_value.__enter__.return_value
        server.login.assert_called_once_with(SETTINGS["EMAIL_USER"], SETTINGS["EMAIL_PASS"])
        message = server.send_message.call_args.args[0]
        self.assertEqual("监听结束", message["Subject"])
        self.assertIn("示例课", message.get_body().get_content())
        attachment, = message.iter_attachments()
        self.assertEqual("listening-log.txt", attachment.get_filename())
        self.assertIn("题目：测试", attachment.get_content())
        self.assertNotIn(SETTINGS["EMAIL_PASS"], message.as_string())

    def test_starttls_is_required_before_login(self):
        with mock.patch.dict(os.environ, {**SETTINGS, "EMAIL_PORT": "587", "EMAIL_SECURITY": "starttls"}, clear=True), \
                mock.patch("util.notice.smtplib.SMTP") as smtp:
            self.assertTrue(send_email("subject", "body"))
        server = smtp.return_value.__enter__.return_value
        self.assertEqual(["ehlo", "starttls", "ehlo", "login", "send_message"],
                         [call[0] for call in server.method_calls])

    def test_smtp_failure_does_not_raise_or_print_credentials(self):
        output = io.StringIO()
        with mock.patch.dict(os.environ, SETTINGS, clear=True), \
                mock.patch("util.notice.smtplib.SMTP_SSL") as smtp, \
                contextlib.redirect_stdout(output):
            smtp.return_value.__enter__.return_value.login.side_effect = smtplib.SMTPAuthenticationError(
                535, b"private-test-password rejected"
            )
            self.assertFalse(send_email("subject", "body"))
        self.assertIn("SMTPAuthenticationError", output.getvalue())
        self.assertNotIn("private-test-password", output.getvalue())
        self.assertNotIn(SETTINGS["EMAIL_PASS"], output.getvalue())

    def test_invalid_port_or_security_never_connects(self):
        for overrides in ({"EMAIL_PORT": "invalid"}, {"EMAIL_PORT": "0"}, {"EMAIL_SECURITY": "plain"}):
            with self.subTest(overrides=overrides), \
                    mock.patch.dict(os.environ, {**SETTINGS, **overrides}, clear=True), \
                    mock.patch("util.notice.smtplib.SMTP_SSL") as smtp:
                self.assertFalse(send_email("subject", "body"))
            smtp.assert_not_called()


if __name__ == "__main__":
    unittest.main()
