import os
import re
from util.file import read

host = "https://changjiang.yuketang.cn/"

api = {
    # 获取收到的消息
    "get_received": "api/v3/activities/received/",
    # 获取我发布的信息
    "get_published": "api/v3/activities/published/",
    # 进入课堂
    "sign_in_class": "api/v3/lesson/checkin",
    # 登录雨课堂账号
    "login_user": "pc/login/verify_pwd_login/",
    # 个人信息
    "user_info": "v2/api/web/userinfo",
    # 如果是课堂 可以通过此URL进入课堂查看PPT 尾接courseID
    "class_info": "m/v2/lesson/student/",
    # 获取正在处于上课的列表
    "get_listening": "api/v3/classroom/on-lesson-upcoming-exam",
    # 获取PPT
    "get_ppt": "api/v3/lesson/presentation/fetch?presentation_id={}",
    # websocket
    "websocket": "wss://changjiang.yuketang.cn/wsapp/",
    # 答题
    "answer": "api/v3/lesson/problem/answer"
}

log_file_name = "log.json"
config_file_name = "config.ini"

# 是否从本地config.ini读取
isLocal = False

# 环境变量模式不依赖本地配置文件
config_file = read(config_file_name) if isLocal else []

sessionId = re.search(r'\"(.*?)\"', config_file[0]).group(1) if isLocal else os.environ["SESSION"]
# email_user = str(re.search(r'\"(.*?)\"', config_file[1]).group(1)) if isLocal else os.environ["EMAIL_USER"]
# email_pass = str(re.search(r'\"(.*?)\"', config_file[2]).group(1)) if isLocal else os.environ["EMAIL_PASS"]
# to_email = str(re.search(r'\"(.*?)\"', config_file[3]).group(1)) if isLocal else os.environ["TO_EMAIL"]
# email_host = str(re.search(r'\"(.*?)\"', config_file[4]).group(1)) if isLocal else os.environ["EMAIL_HOST"]
# email_port = int(re.search(r'\"(.*?)\"', config_file[5]).group(1)) if isLocal else os.environ["EMAIL_PORT"]
ai_key = str(re.search(r'\"(.*?)\"', config_file[1]).group(1)) if isLocal else os.getenv("AI_KEY", "")
enncy_key = str(re.search(r'\"(.*?)\"', config_file[2]).group(1)) if isLocal else os.getenv("ENNCY_KEY", "")

headers = {
    "Cookie": "sessionid=" + sessionId
}

question_type = {
    1: "单选题",
    2: "多选题",
    3: "投票题",
    4: "填空题",
    5: "主观题"
}

# 签到来源 二维码 APP 公众号 默认为二维码
check_in_sources = {
    "公众号": 5,
    "二维码": 21,
    "暗号": 22,
    "APP": 23
}


def get_filtered_courses_from_env():
    raw = os.getenv("FILTERED_COURSES", "")
    return [s.strip() for s in raw.split(",") if s.strip()]


if isLocal:
    filtered_courses = [
        # 默认为空 所有课题监听课程测试
        # 若填写课程名称 则只监听列表里的课，其余课仅签到,建议按自己需求添加
        "计算机组成原理", "数据结构", "牢大"
    ]
else:
    filtered_courses = get_filtered_courses_from_env()
