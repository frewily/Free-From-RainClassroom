package top.frewily.rainclient

import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "top.frewily.rainclient/session_cookie"
        ).setMethodCallHandler { call, result ->
            if (call.method != "readCookieHeader" || call.arguments != null) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                // Fixed app-private WebView origin; no arbitrary host or JS API.
                result.success(
                    CookieManager.getInstance().getCookie("https://changjiang.yuketang.cn/")
                )
            } catch (_: Exception) {
                result.error("cookie_read_failed", "暂时无法读取登录状态", null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "top.frewily.rainclient/cloudflare_callback").setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            val owner = args?.get("owner") as? String
            if (owner == null || !Regex("^[A-Za-z0-9_-]{16,64}$").matches(owner)) {
                result.error("invalid_callback", "无法准备授权返回通道", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "start" -> {
                        val state = args["state"] as? String
                        if (state == null || !Regex("^[A-Za-z0-9_-]{32,128}$").matches(state)) {
                            result.error("invalid_callback", "无法准备授权返回通道", null)
                        } else { CloudflareCallbackReceiver.start(owner, state); result.success(true) }
                    }
                    "await" -> CloudflareCallbackReceiver.await(owner, result)
                    "stop" -> result.success(CloudflareCallbackReceiver.stop(owner))
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("callback_unavailable", "暂时无法准备授权返回通道", null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "top.frewily.rainclient/cloudflare_return").setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            val owner = args?.get("owner") as? String
            if (args?.keys != setOf("owner") || owner == null ||
                !Regex("^[A-Za-z0-9_-]{16,64}$").matches(owner)) {
                result.error("invalid_return_guard", "无法准备授权返回通道", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "start" -> { CloudflareReturnService.start(this, owner); result.success(true) }
                    "stop" -> result.success(CloudflareReturnService.stop(this, owner))
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("return_guard_unavailable", "暂时无法保持授权返回通道", null)
            }
        }
    }
}
