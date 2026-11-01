const officialLoginHosts = {
  'changjiang.yuketang.cn',
  'open.weixin.qq.com',
  'login.weixin.qq.com',
  'mp.weixin.qq.com',
};

bool allowsLoginNavigation(Uri uri) {
  if (uri.toString() == 'about:blank') return true;
  return uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      officialLoginHosts.contains(uri.host.toLowerCase());
}

bool allowsWechatLaunch(Uri uri, String? pageHost) =>
    uri.scheme == 'weixin' &&
    uri.userInfo.isEmpty &&
    uri.toString().length <= 8192 &&
    pageHost != null &&
    officialLoginHosts.contains(pageHost.toLowerCase());
