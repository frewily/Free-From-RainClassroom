import threading
import time
import unittest
from unittest import mock

from function.listener_supervisor import ListenerError, ListenerSupervisor


class ListenerSupervisorTests(unittest.TestCase):
    def test_terminal_error_wakes_waiter_and_keeps_only_safe_details(self):
        for error_type in (RuntimeError, SystemExit):
            with self.subTest(error=error_type.__name__):
                supervisor = ListenerSupervisor()
                release = threading.Event()

                def fail():
                    release.wait(2)
                    raise error_type("private-token")

                with mock.patch.object(threading, "excepthook") as uncaught:
                    supervisor.start(fail, lesson_id=123, kwargs={})
                    try:
                        self.assertFalse(supervisor.stop_event.is_set())
                        release.set()
                        self.assertTrue(supervisor.stop_event.wait(1))
                        with self.assertRaises(ListenerError) as caught:
                            supervisor.raise_if_failed()
                        self.assertIn("123", str(caught.exception))
                        self.assertIn(error_type.__name__, str(caught.exception))
                        self.assertNotIn("private-token", str(caught.exception))
                    finally:
                        release.set()
                        supervisor.stop_and_join()
                uncaught.assert_not_called()

    def test_later_listener_failure_interrupts_wait_for_first_listener(self):
        supervisor = ListenerSupervisor()
        release = threading.Event()

        def fail():
            release.wait(2)
            raise ValueError("private-token")

        first = supervisor.start(lambda: supervisor.stop_event.wait(2), lesson_id=1, kwargs={})
        supervisor.start(fail, lesson_id=2, kwargs={})
        try:
            release.set()
            with self.assertRaises(ListenerError):
                supervisor.wait_until_done()
        finally:
            release.set()
            supervisor.stop_and_join()
        self.assertFalse(first.is_alive())

    def test_normal_completion_does_not_report_failure(self):
        supervisor = ListenerSupervisor()
        try:
            supervisor.start(lambda: None, lesson_id=123, kwargs={})
            supervisor.wait_until_done()
            self.assertFalse(supervisor.stop_event.is_set())
        finally:
            supervisor.stop_and_join()
        supervisor.raise_if_failed()

    def test_partial_start_failure_stops_already_started_listener(self):
        supervisor = ListenerSupervisor()
        first = supervisor.start(lambda: supervisor.stop_event.wait(2), lesson_id=1, kwargs={})
        try:
            with mock.patch.object(threading.Thread, "start", side_effect=RuntimeError("private-token")):
                with self.assertRaises(ListenerError) as caught:
                    supervisor.start(lambda: None, lesson_id=2, kwargs={})
            self.assertIn("启动失败", str(caught.exception))
            self.assertNotIn("private-token", str(caught.exception))
        finally:
            supervisor.stop_and_join()
        self.assertFalse(first.is_alive())

    def test_failure_during_shutdown_remains_observable(self):
        supervisor = ListenerSupervisor()

        def fail_on_stop():
            supervisor.stop_event.wait(2)
            raise ValueError("private-token")

        supervisor.start(fail_on_stop, lesson_id=123, kwargs={})
        supervisor.stop_and_join()
        with self.assertRaises(ListenerError):
            supervisor.raise_if_failed()

    def test_shutdown_has_one_shared_wait_budget(self):
        supervisor = ListenerSupervisor()
        release = threading.Event()
        workers = [supervisor.start(lambda: release.wait(2), lesson_id=i, kwargs={}) for i in (1, 2)]
        try:
            before = time.monotonic()
            supervisor.stop_and_join(timeout=0.03)
            self.assertLess(time.monotonic() - before, 0.5)
            self.assertTrue(all(worker.is_alive() for worker in workers))
        finally:
            release.set()
            for worker in workers:
                worker.join(timeout=1)


if __name__ == "__main__":
    unittest.main()
