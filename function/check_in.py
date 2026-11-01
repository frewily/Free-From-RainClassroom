import requests

from function.listening_socket import start_all_sockets
from function.user import get_user_name
from config import host, api, headers, log_file_name,check_in_sources
from util.file import write_log, read_log
from util.notice import email_notice
from util.timestamp import get_now


class SessionError(RuntimeError):
    """The RainClassroom session can no longer be used safely."""


class CheckInError(RuntimeError):
    """A check-in response did not confirm usable classroom credentials."""


SESSION_HELP = (
    "请检查或更新 GitHub Actions 的 SESSION Secret 后重试；"
    "若仍失败，请检查雨课堂服务状态。"
)

CHECK_IN_STATUS = "已取得课堂连接凭据（未核验个人考勤）"


def _check_in_credentials(response):
    if response.status_code in (401, 403):
        raise SessionError(
            f"雨课堂签到接口返回 HTTP {response.status_code}（未授权）。{SESSION_HELP}"
        )
    if response.status_code != 200:
        raise CheckInError(f"进班请求返回 HTTP {response.status_code}，未取得有效课堂凭据。")
    try:
        payload = response.json()
    except ValueError:
        raise CheckInError("进班接口返回非 JSON 内容，无法确认结果。") from None
    code = payload.get("code") if isinstance(payload, dict) else None
    if type(code) is not int:
        raise CheckInError("进班接口缺少有效业务状态，无法确认结果。")
    if code != 0:
        # Do not echo server messages or assign QR semantics to an undocumented code.
        raise CheckInError(f"进班请求被拒绝（业务码 {code}），未取得有效课堂凭据。")
    data = payload.get("data")
    if not isinstance(data, dict):
        raise CheckInError("进班接口返回的课堂凭据不完整，无法开始监听。")
    socket_jwt = data.get("lessonToken")
    jwt = response.headers.get("Set-Auth")
    identity_id = data.get("identityId")
    valid_identity = type(identity_id) is int or (
        isinstance(identity_id, str) and bool(identity_id.strip())
    )
    valid_tokens = all(isinstance(token, str) and token.strip() for token in (socket_jwt, jwt))
    if not valid_tokens or not valid_identity:
        raise CheckInError("进班接口返回的课堂凭据不完整，无法开始监听。")
    return socket_jwt, jwt, identity_id


# 获取正在进行的
def get_listening():
    response = requests.get(host + api["get_listening"], headers=headers, timeout=15)
    if response.status_code in (401, 403):
        raise SessionError(
            f"雨课堂课程接口返回 HTTP {response.status_code}（未授权）。{SESSION_HELP}"
        )
    if response.status_code == 200:
        try:
            response_data = response.json()
        except ValueError:
            raise SessionError(
                f"雨课堂课程接口返回非 JSON 内容，可能是登录过期后的跳转页面。{SESSION_HELP}"
            ) from None
        data = response_data.get("data") if isinstance(response_data, dict) else None
        if not isinstance(data, dict) or not isinstance(data.get("onLessonClassrooms"), list):
            raise SessionError(
                f"雨课堂课程接口缺少有效的课程列表，可能是登录过期或接口变化。{SESSION_HELP}"
            )
        return data
    else:
        response.raise_for_status()
        return None


# 获取正在进行的课堂并且签到、写日志 新的签到方法
def get_listening_classes_and_sign(filtered_courses: list, seen_lesson_ids=None,
                                   window_stop_event=None, quiet_when_empty=False,
                                   supervisor=None):
    response = get_listening()
    name = None

    # 短期存储查看PPT用的JWT、lessonId等信息
    on_lesson_list = []

    if response is None:
        return []
    else:
        classes = list(response["onLessonClassrooms"])
        if len(classes) == 0:
            if not quiet_when_empty:
                print("\n无课")
            return []
        else:
            found_new_class = False
            for item in classes:
                course_name = item["courseName"]
                lesson_id = item["lessonId"]
                if seen_lesson_ids is not None and lesson_id in seen_lesson_ids:
                    continue
                if not found_new_class:
                    print("\n发现上课")
                    found_new_class = True
                response_sign = check_in_on_listening(lesson_id)
                socket_jwt, jwt, identity_id = _check_in_credentials(response_sign)

                status = CHECK_IN_STATUS
                if name is None:
                    name = get_user_name()

                print(course_name, status)

                def queue_on_listening_task():
                    on_lesson_list.append({
                        "ppt_jwt": jwt,
                        "socket_jwt": socket_jwt,
                        "lesson_id": lesson_id,
                        "identity_id": identity_id,
                        "course_name": course_name
                    })

                if len(filtered_courses) == 0:  # 无需过滤 全部进入监听队列
                    queue_on_listening_task()
                else:  # 只监听符合条件的课程 其余的就签到
                    if course_name in filtered_courses:
                        queue_on_listening_task()

                # 将进班响应记录写入本地日志
                new_log = {
                    "id": lesson_id,
                    "title": course_name,
                    "name": course_name,
                    "time": get_now(),
                    "student": name,
                    "status": status,
                    "url": "https://changjiang.yuketang.cn/m/v2/lesson/student/" + str(lesson_id)
                }
                write_log(log_file_name, new_log)
                if seen_lesson_ids is not None:
                    seen_lesson_ids.add(lesson_id)
            return start_all_sockets(on_lesson_list, window_stop_event=window_stop_event,
                                     supervisor=supervisor)


# 获取正在进行的考试
def check_exam():
    response = get_listening()
    if response is None:
        return None
    else:
        exams = list(response["upcomingExam"])
        if len(exams) == 0:
            print("无考试")
            return
        else:
            print("发现考试")
            print(exams)
            # 发邮件提醒
            email_notice(subject="雨课堂考试提醒", content="请打开雨课堂")
            return


# 传入lessonId 签到
def check_in_on_listening(lesson_id):
    sign_data = {
        "source": check_in_sources["二维码"],
        "lessonId": str(lesson_id),
        "joinIfNotIn": True
    }

    response_sign = requests.post(
        host + api["sign_in_class"], headers=headers, json=sign_data, timeout=15
    )
    return response_sign


# 是否已经签过（写入日志）
def has_in_checked(lesson_id):
    logs = read_log(log_file_name)
    if logs and logs[-1]["id"] == lesson_id:
        print("已签过")
        return True
    else:
        return False


# 收到的课程列表前check_num个全部进行签到、写日志 旧的签到方法 弃用
def check_in_on_latest(check_num=1):
    data = {
        "size": check_num,
        "type": [],
        "beginTime": None,
        "endTime": None
    }

    name = get_user_name()
    # 检查收到消息
    response = requests.post(host + api["get_received"], headers=headers, json=data, timeout=(5, 15))
    if response.status_code == 200:
        response_data = response.json()
        # 提取 `data` 列表中的第一个元素信息
        if "data" in response_data and response_data["data"]:
            courseware_info = response_data["data"][0]
            courseware_id = courseware_info.get("coursewareId")
            courseware_title = courseware_info.get("coursewareTitle")
            course_name = courseware_info.get("courseName")

            if has_in_checked(courseware_id):
                return

            print("标题:", courseware_title)
            print("名称:", course_name)

            response_sign = check_in_on_listening(courseware_id)
            _check_in_credentials(response_sign)

            status = CHECK_IN_STATUS

            print(name, status)

            # 将进班响应记录写入本地日志
            new_log = {
                "id": courseware_id,
                "title": courseware_title,
                "name": course_name,
                "time": get_now(),
                "student": name,
                "status": status,
                "url": "https://changjiang.yuketang.cn/m/v2/lesson/student/" + str(courseware_id)
            }
            write_log(log_file_name, new_log)
        else:
            print("没有找到数据")
    else:
        print("请求失败:", response.status_code, response.text)
