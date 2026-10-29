package com.edde746.plezy

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Keeps Plezy's process in the foreground while a player Plezy handed a video
 * to is in front, so Plezy can keep reporting playback to the server. Devices
 * such as Zidoo boxes keep very few background processes, and without this
 * Plezy is reclaimed partway through a film. Started by [ExternalPlayerChannel]
 * just before the launch and stopped when the player answers.
 */
class ExternalPlaybackService : Service() {
  companion object {
    private const val CHANNEL_ID = "external_playback"
    private const val NOTIFICATION_ID = 7462
    private const val EXTRA_TITLE = "title"

    fun start(context: Context, title: String?) {
      val intent = Intent(context, ExternalPlaybackService::class.java).putExtra(EXTRA_TITLE, title)
      try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
          context.startForegroundService(intent)
        } else {
          context.startService(intent)
        }
      } catch (error: Exception) {
        // Best effort: without it the handoff still works, Plezy is just
        // more likely to be reclaimed while the player is in front.
        android.util.Log.w("ExternalPlaybackService", "Could not keep Plezy in the foreground", error)
      }
    }

    fun stop(context: Context) {
      context.stopService(Intent(context, ExternalPlaybackService::class.java))
    }
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager.getNotificationChannel(CHANNEL_ID) == null) {
      manager.createNotificationChannel(
        NotificationChannel(
          CHANNEL_ID,
          getString(R.string.external_playback_channel),
          NotificationManager.IMPORTANCE_LOW
        )
      )
    }
    val notification = NotificationCompat.Builder(this, CHANNEL_ID)
      .setSmallIcon(R.drawable.ic_stat_notification)
      .setContentTitle(intent?.getStringExtra(EXTRA_TITLE) ?: getString(R.string.external_playback_channel))
      .setContentText(getString(R.string.external_playback_text))
      .setOngoing(true)
      .setSilent(true)
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .build()
    val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
    } else {
      0
    }
    try {
      ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
    } catch (error: Exception) {
      android.util.Log.w("ExternalPlaybackService", "Could not enter the foreground", error)
      stopSelf()
    }
    return START_NOT_STICKY
  }
}
