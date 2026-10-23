"""Propagate terminal listener failures to the main thread without raw errors."""

import queue
import threading
import time


class ListenerError(RuntimeError):
    """A classroom listener could not start or terminated with an error."""


class ListenerSupervisor:
    def __init__(self):
        self.stop_event = threading.Event()
        self._failures = queue.Queue()
        self._threads = []

    def _record_failure(self, lesson_id, error_type, phase):
        # Keep only identifiers and exception types, never exception bodies or JWTs.
        self._failures.put(f"课堂 {lesson_id} {phase}：{error_type}")
        self.stop_event.set()

    def start(self, target, *, lesson_id, kwargs):
        self.raise_if_failed()

        def run_listener():
            try:
                target(**kwargs)
            except BaseException as error:
                self._record_failure(lesson_id, type(error).__name__, "监听异常退出")

        worker = threading.Thread(target=run_listener)
        self._threads.append(worker)
        try:
            worker.start()
        except Exception as error:
            self._threads.remove(worker)
            self._record_failure(lesson_id, type(error).__name__, "监听线程启动失败")
            self.raise_if_failed()
        return worker

    def raise_if_failed(self):
        try:
            failure = self._failures.get_nowait()
        except queue.Empty:
            return
        raise ListenerError(failure) from None

    def wait_until_done(self):
        # An error in any listener must interrupt waiting for the other listeners.
        while any(worker.is_alive() for worker in self._threads):
            self.raise_if_failed()
            self.stop_event.wait(0.1)
        self.raise_if_failed()

    def stop_and_join(self, timeout=5):
        self.stop_event.set()
        deadline = time.monotonic() + timeout
        for worker in self._threads:
            worker.join(timeout=max(0, deadline - time.monotonic()))
