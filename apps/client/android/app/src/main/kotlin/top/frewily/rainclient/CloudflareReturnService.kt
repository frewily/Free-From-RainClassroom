package top.frewily.rainclient

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/** User-started, bounded OAuth return window. Contains no authorization data. */
class CloudflareReturnService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var runningOwner: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val owner = intent?.getStringExtra(OWNER)
        if (owner == null || owner != activeOwner) {
            if (activeOwner == null) stopSelf()
            return START_NOT_STICKY
        }
        runningOwner = owner
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL, "官方授权返回", NotificationManager.IMPORTANCE_LOW
            ))
        }
        val open = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pending = PendingIntent.getActivity(this, 0, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
            else Notification.Builder(this)
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("雨课堂管理：正在等待官方授权")
            .setContentText("接收 Cloudflare 返回；完成、取消或超时后自动停止")
            .setContentIntent(pending)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION, notification)
        }
        handler.removeCallbacksAndMessages(null)
        // Independent of Dart timers. Never restart after a task/process exit.
        handler.postDelayed({
            if (activeOwner == owner) {
                activeOwner = null
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }, 12 * 60 * 1000L)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        if (activeOwner == runningOwner) activeOwner = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        private const val OWNER = "owner"
        private const val CHANNEL = "cloudflare_auth_return"
        private const val NOTIFICATION = 8765
        @Volatile private var activeOwner: String? = null

        @Synchronized fun start(context: Context, owner: String) {
            activeOwner = owner
            try {
                val intent = Intent(context, CloudflareReturnService::class.java).putExtra(OWNER, owner)
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (error: Exception) {
                if (activeOwner == owner) activeOwner = null
                throw error
            }
        }

        @Synchronized fun stop(context: Context, owner: String): Boolean {
            if (activeOwner != owner) return false
            activeOwner = null
            context.stopService(Intent(context, CloudflareReturnService::class.java))
            return true
        }
    }
}
