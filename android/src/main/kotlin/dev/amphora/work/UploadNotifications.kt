package dev.amphora.work

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.work.ForegroundInfo
import dev.amphora.model.UploadJob

class UploadNotifications(private val context: Context) {
    fun foregroundInfo(job: UploadJob): ForegroundInfo {
        ensureChannel()
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Uploading")
            .setContentText(job.sourceUri)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setProgress(0, 0, true)
            .build()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }

    // No SDK_INT >= O guard: VERSION_CODES.O is API 26 and minSdk is 26, so the condition was
    // true on every device this library can be installed on and the implicit else was
    // unreachable. The Q guard in foregroundInfo() above is a different matter and stays — 26
    // through 28 genuinely take the two-argument ForegroundInfo.
    private fun ensureChannel() {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Uploads", NotificationManager.IMPORTANCE_LOW),
        )
    }

    private companion object {
        const val CHANNEL_ID = "amphora-uploads"
        const val NOTIFICATION_ID = 0xA6
    }
}
