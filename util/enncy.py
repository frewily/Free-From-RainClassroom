# 言溪题库
import requests
from config import enncy_key
from util.ocr import ocr_form_url_image


def search(q):
    query_params = {
        "token": enncy_key,
        "q": q,
    }
    response = requests.get(url="https://tk.enncy.cn/query", params=query_params, timeout=(5, 15))
    if response.status_code == 200:
        return response.text
    else:
        print("题库搜索失败 是否次数不够了?")
        return None


def ocr_with_search(url):
    return search(ocr_form_url_image(url))
