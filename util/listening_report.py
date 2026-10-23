"""Per-class lifecycle notifications and a bounded, private answer activity log."""

import json
import os
import queue
import threading
import time
from datetime import datetime

from function.listen_window import CHINA_TIME
from util.notice import email_is_configured, send_email


MAX_ENTRIES = 200
MAX_FIELD_LENGTH = 2000
PROCESSOR_DRAIN_SECONDS = 5
MAIL_DRAIN_SECONDS = 5


def report_call(report, method, *args, **kwargs):
    """Notification failures must not change classroom processing or its errors."""
    if report is None:
        return None
    try:
        return getattr(report, method)(*args, **kwargs)
    except Exception as error:
        print(f"监听报告 {method} 失败：{type(error).__name__}；课堂处理继续", flush=True)
        return None


def create_listening_report(course_name, lesson_id, *, sensitive_values=()):
    try:
        if email_is_configured():
            return ListeningReport(course_name, lesson_id, sensitive_values=sensitive_values)
    except Exception as error:
        print(f"监听报告创建失败：{type(error).__name__}；课堂处理继续", flush=True)
    return None


class ListeningReport:
    def __init__(self, course_name, lesson_id, *, sensitive_values=(), sender=None):
        self._secrets = tuple(value for value in (*sensitive_values, *(os.getenv(key, "") for key in (
            "SESSION", "AI_KEY", "ENNCY_KEY", "HFUT_USERNAME", "HFUT_PASSWORD",
            "EMAIL_PASS", "GITHUB_TOKEN", "TEST_TRIGGER_KEY",
        ))) if value)
        self.course_name = self._safe(course_name)
        self.lesson_id = self._safe(lesson_id)
        self._sender = sender or send_email
        self._lock = threading.Lock()
        self._started_at = None
        self._finished = False
        self._end_reason = None
        self._mail_worker = None
        self._mail_queue = queue.Queue()
        self._processors = []
        self._entries = []
        self._omitted = 0
        self._reconnects = 0

    def _safe(self, value):
        text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=str)
        for secret in self._secrets:
            text = text.replace(secret, "[已隐藏]")
        return text[:MAX_FIELD_LENGTH] + ("…（已截断）" if len(text) > MAX_FIELD_LENGTH else "")

    @staticmethod
    def _now():
        return datetime.now(CHINA_TIME).strftime("%Y-%m-%d %H:%M:%S %z")

    def _context(self):
        repository = os.getenv("GITHUB_REPOSITORY", "")
        run_id = os.getenv("GITHUB_RUN_ID", "")
        server = os.getenv("GITHUB_SERVER_URL", "https://github.com")
        run_url = f"{server}/{repository}/actions/runs/{run_id}" if repository and run_id else "本地运行"
        return (f"课程：{self.course_name}\n课堂编号：{self.lesson_id}\n"
                f"Actions：{self._safe(run_url)}")

    def _send(self, subject, content, **kwargs):
        try:
            self._sender(subject=subject, content=content, **kwargs)
        except Exception as error:
            print(f"邮件通知失败：{type(error).__name__}；监听继续", flush=True)

    def _deliver_messages(self):
        while True:
            message = self._mail_queue.get()
            try:
                if message is None:
                    return
                subject, content, attachments = message
                self._send(subject, content, **attachments)
            finally:
                self._mail_queue.task_done()

    def mark_started(self):
        """Called on the first valid classroom response, never just on TCP open."""
        with self._lock:
            if self._started_at is not None or self._finished:
                return
            started_at = self._now()
            content = (f"已收到课堂时间线或题目列表，开始监听。\n{self._context()}\n"
                       f"开始时间（北京时间）：{started_at}\n"
                       "这不代表后续 PPT 获取、题目处理或评分已经成功。\n"
                       "断线重连期间不会重复发送开始通知。")
            title = self.course_name.replace("\r", " ").replace("\n", " ")[:100]
            worker = threading.Thread(
                target=self._deliver_messages,
                name="listening-email",
                daemon=True,
            )
            try:
                worker.start()
            except Exception:
                self._finished = True
                raise
            self._mail_worker = worker
            self._started_at = started_at
            self._mail_queue.put((f"[雨课堂] 已进入监听：{title}", content, {}))

    def track_processor(self, worker):
        with self._lock:
            # Completed reconnect workers need not accumulate for the whole class.
            self._processors = [item for item in self._processors if item.is_alive()]
            self._processors.append(worker)

    def set_end_reason(self, reason):
        with self._lock:
            self._end_reason = self._safe(reason)

    def note_reconnect(self):
        with self._lock:
            self._reconnects += 1

    def begin_answer(self, problem_id, problem_type, content, options):
        with self._lock:
            if self._finished or len(self._entries) >= MAX_ENTRIES:
                self._omitted += 1
                return None
            record = {
                "时间": self._now(), "题号": self._safe(problem_id),
                "题型": self._safe(problem_type), "题目": self._safe(content),
                "选项": self._safe(options), "本次结果": "尚未生成",
                "状态": "退出时仍在处理，尚未取得接口结果",
            }
            self._entries.append(record)
            return record

    def update_answer(self, record, *, result=None, status=None):
        if record is None:
            return
        with self._lock:
            if self._finished:
                return
            if result is not None:
                record["本次结果"] = self._safe(result)
            if status is not None:
                record["状态"] = self._safe(status)

    def finish(self, reason):
        # Existing AI/HTTP calls cannot always be interrupted. Wait briefly, then
        # explicitly label any still-running entry rather than claiming success.
        with self._lock:
            if self._finished:
                return
            if self._started_at is None:
                self._finished = True
                return
            processors = list(self._processors)
        deadline = time.monotonic() + PROCESSOR_DRAIN_SECONDS
        for worker in processors:
            if worker is not threading.current_thread():
                worker.join(timeout=max(0, deadline - time.monotonic()))
        with self._lock:
            if self._finished:
                return
            self._finished = True
            if self._started_at is None:
                return
            ended_at = self._now()
            content = (f"本次课堂监听已结束。\n{self._context()}\n"
                       f"开始时间（北京时间）：{self._started_at}\n"
                       f"结束时间（北京时间）：{ended_at}\n"
                       f"结束原因：{self._end_reason or self._safe(reason)}\n"
                       f"重连次数：{self._reconnects}\n记录条数：{len(self._entries)}\n"
                       "附件记录本次已有题目处理与接口返回，不代表答案正确或评分成功。")
            lines = [content, "", "本次题目处理日志（结构化记录，已对已知凭据原值脱敏）："]
            for index, entry in enumerate(self._entries, 1):
                lines.append(f"\n--- 记录 {index} ---")
                lines.extend(f"{key}：{value}" for key, value in entry.items())
            if not self._entries:
                lines.append("本次没有题目处理记录。")
            if self._omitted:
                lines.append(f"\n另有 {self._omitted} 条记录未保存（最多保留 {MAX_ENTRIES} 条）。")
            title = self.course_name.replace("\r", " ").replace("\n", " ")[:100]
            self._mail_queue.put((f"[雨课堂] 监听结束：{title}", content, {
                "attachment_text": "\n".join(lines), "attachment_name": "listening-log.txt",
            }))
            self._mail_queue.put(None)
            worker = self._mail_worker
        # A stalled SMTP/DNS call cannot be killed safely from another Python
        # thread. Bound the wait and let this daemon stop with the process.
        worker.join(timeout=MAIL_DRAIN_SECONDS)
        if worker.is_alive():
            print("邮件发送尚未完成，停止等待；后台发送可能在进程退出时中断", flush=True)
