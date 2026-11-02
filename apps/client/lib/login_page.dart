import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'auth/cookie_reader.dart';
import 'auth/login_navigation.dart';
import 'auth/session_client.dart';
import 'auth/session_controller.dart';
import 'auth/session_store.dart';
import 'courses/course_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    this.store,
    this.verifier,
    this.cookies,
    this.loginViewBuilder,
    this.coursesPageBuilder,
  });
  final SessionStore? store;
  final SessionVerifier? verifier;
  final SessionCookieSource? cookies;
  final WidgetBuilder? loginViewBuilder;
  final WidgetBuilder? coursesPageBuilder;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final SessionController _session;
  late final SessionStore _store;
  WebViewController? _web;
  bool _showLogin = false;
  bool _openingWechat = false;
  int _viewGeneration = 0;
  int _progress = 0;
  String? _trustedHost;
  String? _pageError;
  static final _loginUrl = Uri.parse('https://changjiang.yuketang.cn/web');
  // The official desktop login uses a 950px wrapper and a 416px card.
  // Only its presentation changes; login controls and requests remain official.
  static const _mobileLoginLayout = r'''
(() => {
  if (location.protocol !== 'https:' || location.hostname !== 'changjiang.yuketang.cn' ||
      !document.querySelector('.J_login.login-wraper') ||
      document.getElementById('rainclient-mobile-login')) return;
  const style = document.createElement('style');
  style.id = 'rainclient-mobile-login';
  style.textContent = `@media (max-width: 600px) {
    .J_login.login-wraper { overflow: auto; }
    .J_login.login-wraper .wrapper-inner { width: 100% !important; height: auto !important; min-height: 100%; padding: 24px 0; box-sizing: border-box; }
    .J_login.login-wraper .login-box,
    .J_login.login-wraper .server-wrapper,
    .J_login.login-wraper .download-box { max-width: calc(100% - 24px); }
    .J_login.login-wraper .L_title { height: auto; flex-wrap: wrap; row-gap: 8px; font-size: 20px; }
    .J_login.login-wraper .L_title .download-entry,
    .J_login.login-wraper .L_title .language { position: static; transform: none; margin: 0 8px; }
    .J_login.login-wraper .tab-box { flex-wrap: wrap; row-gap: 16px; }
    .page-footer.J_login { position: relative; height: auto; line-height: 1.6; }
    .page-footer.J_login .footer-inner { width: 100%; padding: 12px; box-sizing: border-box; }
    .page-footer.J_login .footer-inner > * { float: none; overflow-wrap: anywhere; }
  }`;
  document.head.appendChild(style);
})();
''';

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? SecureSessionStore();
    _session = SessionController(
      store: _store,
      verifier: widget.verifier ?? SessionClient(),
      cookies: widget.cookies ?? PlatformSessionCookies(),
      closeLoginView: _closeLoginView,
    );
    unawaited(_session.restore());
  }

  bool _isViewCurrent(int generation) =>
      mounted && generation == _viewGeneration && _session.inLoginFlow;

  Future<void> _openCourses() async {
    final needsLogin = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder:
            widget.coursesPageBuilder ?? (_) => CoursePage(sessions: _store),
      ),
    );
    if (mounted && needsLogin == true) await _session.restore();
  }

  Future<void> _closeLoginView() async {
    _viewGeneration++;
    final view = _web;
    _web = null;
    _trustedHost = null;
    if (view != null) {
      try {
        await _blankLoginView(view).timeout(const Duration(seconds: 3));
      } on Object {
        // The native view may already be gone. Cookie cleanup still runs.
      }
    }
    if (mounted && (_showLogin || _pageError != null)) {
      final hadLoginView = _showLogin;
      setState(() {
        _showLogin = false;
        _pageError = null;
      });
      if (hadLoginView) {
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(seconds: 3),
        );
      }
    }
  }

  Future<void> _openLogin() async {
    setState(() => _pageError = null);
    if (!await _session.beginLogin() || !mounted) return;
    final generation = ++_viewGeneration;
    try {
      if (widget.loginViewBuilder == null) {
        final controller = WebViewController();
        _web = controller;
        await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
        await controller.setBackgroundColor(const Color(0xffffffff));
        // Website console output is not a credential-safe diagnostic channel.
        await controller.setOnConsoleMessage((_) {});
        await controller.setNavigationDelegate(
          NavigationDelegate(
            onProgress: (value) {
              if (_isViewCurrent(generation)) setState(() => _progress = value);
            },
            onPageStarted: (url) {
              if (!_isViewCurrent(generation)) return;
              final uri = Uri.tryParse(url);
              if (uri != null &&
                  allowsLoginNavigation(uri) &&
                  uri.scheme == 'https') {
                setState(() => _trustedHost = uri.host);
              }
            },
            onPageFinished: (_) async {
              if (!_isViewCurrent(generation) ||
                  defaultTargetPlatform != TargetPlatform.android) {
                return;
              }
              try {
                await controller.runJavaScript(_mobileLoginLayout);
              } on Object {
                // A cosmetic adjustment must not interrupt official login.
              }
            },
            onNavigationRequest: (request) async {
              if (!_isViewCurrent(generation)) {
                return NavigationDecision.prevent;
              }
              final uri = Uri.tryParse(request.url);
              if (uri != null && allowsLoginNavigation(uri)) {
                return NavigationDecision.navigate;
              }
              if (uri != null && allowsWechatLaunch(uri, _trustedHost)) {
                unawaited(_openWechat(uri, generation));
              } else {
                final host = uri?.host;
                setState(
                  () => _pageError = host != null && host.isNotEmpty
                      ? '暂不支持前往 $host，请保留此提示用于排查。'
                      : '该跳转暂不支持，请返回官方登录页继续操作。',
                );
              }
              return NavigationDecision.prevent;
            },
            onWebResourceError: (error) {
              if (_isViewCurrent(generation) && error.isForMainFrame == true) {
                setState(() => _pageError = '官方登录页面暂时未能加载，请检查网络后重试。');
              }
            },
          ),
        );
        if (defaultTargetPlatform == TargetPlatform.android) {
          await AndroidWebViewController.enableDebugging(false);
          await (controller.platform as AndroidWebViewController)
              .setUseWideViewPort(true);
        }
      }
      if (!_isViewCurrent(generation)) return;
      setState(() {
        _showLogin = true;
        _progress = 0;
        _trustedHost = _loginUrl.host;
      });
      await _web?.loadRequest(_loginUrl);
    } on Object {
      if (!_isViewCurrent(generation)) return;
      await _session.cancelLogin();
      if (mounted) setState(() => _pageError = '暂时无法打开系统网页组件，请稍后重试。');
    }
  }

  Future<void> _blankLoginView(WebViewController view) async {
    // Public APIs replace the document and stop its JavaScript before cleanup.
    await view.setJavaScriptMode(JavaScriptMode.disabled);
    await view.loadHtmlString('<!doctype html><html></html>');
  }

  Future<void> _openWechat(Uri uri, int generation) async {
    if (_openingWechat || !_isViewCurrent(generation)) return;
    _openingWechat = true;
    try {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('打开微信完成官方操作？'),
          content: const Text('官网请求打开微信。完成操作后返回应用，再检查登录状态。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('留在应用'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('打开微信'),
            ),
          ],
        ),
      );
      if (approved != true || !_isViewCurrent(generation)) return;
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && _isViewCurrent(generation)) {
        setState(() => _pageError = '暂时无法打开微信，请使用官方页面提供的其他登录方式。');
      }
    } on Object {
      if (_isViewCurrent(generation)) {
        setState(() => _pageError = '暂时无法打开微信，请返回官方页面继续操作。');
      }
    } finally {
      _openingWechat = false;
    }
  }

  @override
  void dispose() {
    _viewGeneration++;
    _session.dispose();
    final view = _web;
    if (view != null) {
      unawaited(_blankLoginView(view).catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _session,
    builder: (context, _) => PopScope(
      canPop: !_showLogin && !_session.inLoginFlow,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_session.cancelLogin());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _showLogin
              ? IconButton(
                  onPressed: _session.cancelLogin,
                  tooltip: '取消本次登录',
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
          title: Text(
            _showLogin ? '雨课堂官方登录' : '雨课堂管理',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          actions: [
            if (_showLogin)
              IconButton(
                tooltip: '重新加载官方页面',
                onPressed: _session.busy
                    ? null
                    : () async {
                        setState(() => _pageError = null);
                        await _web?.reload();
                      },
                icon: const Icon(Icons.refresh),
              )
            else
              const Padding(
                padding: EdgeInsets.only(right: 24),
                child: Center(
                  child: Text(
                    '开发版',
                    style: TextStyle(fontSize: 12, color: Color(0xff6c7e77)),
                  ),
                ),
              ),
          ],
        ),
        body: _showLogin ? _loginBody(context) : _overview(context),
      ),
    ),
  );

  Widget _loginBody(BuildContext context) => SafeArea(
    top: false,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.lock_outline, size: 15),
              const SizedBox(width: 8),
              Text(
                _trustedHost ?? _loginUrl.host,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        if (_progress < 100)
          LinearProgressIndicator(value: _progress / 100, minHeight: 2),
        Expanded(
          child: AbsorbPointer(
            absorbing: _session.busy,
            child:
                widget.loginViewBuilder?.call(context) ??
                WebViewWidget(controller: _web!),
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
          decoration: const BoxDecoration(
            color: Color(0xfff5f4ed),
            border: Border(top: BorderSide(color: Color(0xffd6ded6))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_pageError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    _pageError!,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: Color(0xff9b3c32),
                    ),
                  ),
                ),
              Text(
                _session.message,
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('check-login'),
                onPressed: _session.busy ? null : _session.checkLogin,
                icon: _session.busy
                    ? const _SmallSpinner()
                    : const Icon(Icons.check_circle_outline),
                label: Text(_session.busy ? '正在检查登录' : '我已完成登录，检查状态'),
              ),
              TextButton(
                onPressed: _session.cancelLogin,
                child: const Text('取消本次登录'),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _overview(BuildContext context) {
    final phase = _session.phase;
    final loggedIn = phase == LoginPhase.loggedIn;
    final status = switch (phase) {
      LoginPhase.preparing => '正在准备',
      LoginPhase.loggedOut => '还未登录',
      LoginPhase.loggingIn => '等待官方登录',
      LoginPhase.checking => '正在检查',
      LoginPhase.loggedIn => '已登录',
      LoginPhase.needsLogin => '需要重新登录',
      LoginPhase.unavailable => '登录状态待确认',
      LoginPhase.error => '操作尚未完成',
    };
    final retry = phase == LoginPhase.error || phase == LoginPhase.unavailable;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 30, 28, 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.water_drop_outlined,
                  size: 36,
                  color: Color(0xff28685e),
                ),
                const SizedBox(height: 28),
                const Text(
                  '连接你的\n雨课堂',
                  style: TextStyle(
                    fontFamily: 'serif',
                    fontSize: 44,
                    height: 1.18,
                    color: Color(0xff173b3c),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  '在官方页面正常登录。\n登录信息会安全保存在这台设备。',
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.8,
                    color: Color(0xff61726b),
                  ),
                ),
                const SizedBox(height: 36),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: const Color(0xfffdfdf8),
                    border: Border.all(color: const Color(0xffd6ded6)),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '本机登录状态',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xff6c7e77),
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          if (_session.busy)
                            const _SmallSpinner()
                          else
                            Icon(
                              loggedIn
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              size: 21,
                              color: const Color(0xff28685e),
                            ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              status,
                              key: const ValueKey('login-status'),
                              style: const TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w600,
                                color: Color(0xff173b3c),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _pageError ?? _session.message,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.7,
                          color: Color(0xff61726b),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                if (loggedIn) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('open-courses'),
                      onPressed: _openCourses,
                      icon: const Icon(Icons.checklist),
                      label: const Text('选择课程班级'),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('primary-login-action'),
                    onPressed: _session.busy
                        ? null
                        : retry
                        ? _session.retry
                        : _openLogin,
                    icon: _session.busy
                        ? const _SmallSpinner()
                        : Icon(retry ? Icons.refresh : Icons.login),
                    label: Text(
                      _session.busy
                          ? '正在处理'
                          : retry
                          ? '重试'
                          : loggedIn
                          ? '重新登录'
                          : '前往官方登录',
                    ),
                  ),
                ),
                if (phase == LoginPhase.unavailable)
                  Center(
                    child: TextButton(
                      onPressed: _openLogin,
                      child: const Text('重新登录'),
                    ),
                  ),
                if (_session.hasSavedSession || phase == LoginPhase.error)
                  Center(
                    child: TextButton(
                      key: const ValueKey('local-logout'),
                      onPressed: _session.logout,
                      child: const Text('退出本机登录'),
                    ),
                  ),
                const SizedBox(height: 28),
                const Divider(color: Color(0xffd6ded6)),
                const SizedBox(height: 12),
                const Text(
                  '退出本机登录与云端监听的启停是独立操作。\n课程选择只保存在本机，尚未启用监听。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.8,
                    color: Color(0xff79877e),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SmallSpinner extends StatelessWidget {
  const _SmallSpinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 18,
    height: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
