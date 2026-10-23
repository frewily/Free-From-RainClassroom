import os
import sys
from datetime import datetime

import requests

from config import filtered_courses
from function.course_schedule import current_monitor_window
from function.check_in import SessionError, get_listening_classes_and_sign
from function.listener_supervisor import ListenerError, ListenerSupervisor
from function.listen_window import CHINA_TIME


CHECK_INTERVAL_SECONDS = 300


def main():
    supervisor = ListenerSupervisor()
    try:
        run_listening(supervisor)
    finally:
        supervisor.stop_and_join()
    # Also catch a listener that failed while the main thread was shutting down.
    supervisor.raise_if_failed()


def run_listening(supervisor):
    window_end = current_monitor_window(filtered_courses)
    if window_end is None:
        if os.getenv("GITHUB_EVENT_NAME") == "workflow_dispatch" or not os.getenv("GITHUB_ACTIONS"):
            print("手动单次检查课程", flush=True)
            get_listening_classes_and_sign(
                filtered_courses, window_stop_event=supervisor.stop_event,
                supervisor=supervisor,
            )
            supervisor.wait_until_done()
        else:
            print("当前不在监听窗口，退出", flush=True)
        return

    print("进入配置的监听窗口", flush=True)
    seen_lesson_ids = set()
    while datetime.now(CHINA_TIME) < window_end:
        supervisor.raise_if_failed()
        try:
            get_listening_classes_and_sign(
                filtered_courses,
                seen_lesson_ids=seen_lesson_ids,
                window_stop_event=supervisor.stop_event,
                quiet_when_empty=True,
                supervisor=supervisor,
            )
        except requests.RequestException as error:
            print(f"检查课程暂时失败: {type(error).__name__}", flush=True)

        supervisor.raise_if_failed()
        remaining = (window_end - datetime.now(CHINA_TIME)).total_seconds()
        if remaining <= 0:
            break
        supervisor.stop_event.wait(min(CHECK_INTERVAL_SECONDS, remaining))
        supervisor.raise_if_failed()
    print("监听时间窗结束，开始收尾", flush=True)


def run():
    try:
        main()
    except (SessionError, ListenerError) as error:
        print(f"运行停止：{error}", file=sys.stderr, flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    run()
