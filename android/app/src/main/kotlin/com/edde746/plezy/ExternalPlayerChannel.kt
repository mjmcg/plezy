package com.edde746.plezy

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.Parcelable
import android.os.StrictMode
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import org.json.JSONObject

internal class ExternalPlayerChannel(private val activity: Activity) {
  companion object {
    private const val CHANNEL = "com.plezy/external_player"
    const val REQUEST_CODE = 7461

    private const val API_MX_RETURN_RESULT = "return_result"
    private const val API_MX_RESULT_ID = "com.mxtech.intent.result.VIEW"
    private const val API_MX_RESULT_POSITION = "position"
    private const val API_MX_RESULT_DURATION = "duration"
    private const val API_MX_RESULT_END_BY = "end_by"
    private const val API_MX_RESULT_END_BY_PLAYBACK_COMPLETION = "playback_completion"
    private const val API_MX_TITLE = "title"
    private const val API_MX_FILENAME = "filename"
    private const val API_MX_SECURE_URI = "secure_uri"
    private const val API_VLC_RESULT_POSITION = "extra_position"
    private const val API_VLC_RESULT_DURATION = "extra_duration"

    // Honored by VLC and the native Zidoo player (com.android.gallery3d /
    // com.zidoo.player). Without it, a launch with no resume point lets the
    // player consult its own bookmark store, which on Zidoo collides across
    // Plex items because every part URL ends in the same `file.<ext>` (#2223).
    private const val API_VLC_FROM_START = "from_start"

    private const val API_VIMU_TITLE = "forcename"
    private const val API_VIMU_SEEK_POSITION = "startfrom"
    private const val API_VIMU_RESUME = "forceresume"
    private const val API_VIMU_RESULT_ID = "net.gtvbox.videoplayer.result"
    private const val API_VIMU_RESULT_ERROR = 4
    private const val API_VIMU_RESULT_PLAYBACK_COMPLETED = 1

    // MX Player's subtitle API; mpv-android reads `subs` and `subs.enable`,
    // Just Player `subs`, `subs.name` and `subs.enable`. VLC only takes
    // `subtitles_location`, which it opens as a local file path, so remote
    // sidecars cannot reach it that way.
    private const val API_SUBS = "subs"
    private const val API_SUBS_NAME = "subs.name"
    private const val API_SUBS_FILENAME = "subs.filename"
    private const val API_SUBS_ENABLE = "subs.enable"

    // The native Zidoo player's track API (firmware 6.4.42+ on Z9X/Z9X Pro,
    // 1.1.42+ on the Z9X 8K line): `audio_idx` counts the file's audio
    // streams from 0, `subtitle_idx` its subtitle streams from 1.
    private const val API_ZIDOO_AUDIO_INDEX = "audio_idx"
    private const val API_ZIDOO_SUBTITLE_INDEX = "subtitle_idx"

    /** The Zidoo player activity on current firmware. */
    internal const val ZIDOO_PLAYER_COMPONENT = "com.zidoo.player/com.zidoo.player.activity.PlayerActivity"

    /**
     * The player older Zidoo firmware ships. AOSP's Gallery carries the same
     * activity on other devices, so it only counts on a Zidoo.
     */
    internal const val ZIDOO_LEGACY_PLAYER_COMPONENT = "com.android.gallery3d/com.android.gallery3d.app.MovieActivity"

    private val positionExtras = arrayOf(API_MX_RESULT_POSITION, API_VLC_RESULT_POSITION)
    private val durationExtras = arrayOf(API_MX_RESULT_DURATION, API_VLC_RESULT_DURATION)

    // A launch outlives this process when the device reclaims it while the
    // player is in front (Zidoo firmware keeps two background processes), and
    // the player's result then reaches a fresh activity with no channel call
    // waiting. Dart's description of the launch is kept here until the result
    // arrives, and an unclaimed result until Dart takes it.
    private const val PREFS = "external_player_handoff"
    private const val KEY_PENDING_SESSION = "pending_session"
    private const val KEY_ORPHANED_RESULT = "orphaned_result"

    /** Whether [component] names the Zidoo player on [manufacturer]'s device. */
    internal fun isZidooComponent(component: String, manufacturer: String): Boolean = when (component) {
      ZIDOO_PLAYER_COMPONENT -> true
      ZIDOO_LEGACY_PLAYER_COMPONENT -> manufacturer.contains("zidoo", ignoreCase = true)
      else -> false
    }
  }

  private var pendingResult: MethodChannel.Result? = null

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
  }

  fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode != REQUEST_CODE) return false
    val result = pendingResult
    pendingResult = null
    ExternalPlaybackService.stop(activity)
    val built = buildResult(resultCode, data)
    val session = prefs().getString(KEY_PENDING_SESSION, null)
    if (result == null) {
      if (session == null) {
        android.util.Log.w("ExternalPlayerChannel", "Result received without a pending channel call")
      } else {
        android.util.Log.i("ExternalPlayerChannel", "Keeping a player result that outlived its launch for Dart to claim")
        prefs().edit()
          .putString(KEY_ORPHANED_RESULT, orphanedResultJson(session, built))
          .remove(KEY_PENDING_SESSION)
          .commit()
      }
    } else {
      if (session != null) prefs().edit().remove(KEY_PENDING_SESSION).apply()
      result.success(built)
    }
    return true
  }

  private fun prefs() = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  internal fun orphanedResultJson(session: String, result: Map<String, Any?>): String = JSONObject().apply {
    put("session", session)
    for (key in listOf("positionMs", "durationMs", "playbackCompleted", "playbackError")) {
      result[key]?.let { put(key, it) }
    }
  }.toString()

  /** The result [onActivityResult] kept for a launch this process never made, once. */
  private fun takeOrphanedResult(): Map<String, Any?>? {
    val json = prefs().getString(KEY_ORPHANED_RESULT, null) ?: return null
    prefs().edit().remove(KEY_ORPHANED_RESULT).apply()
    return try {
      val obj = JSONObject(json)
      mapOf(
        "session" to obj.getString("session"),
        "positionMs" to (if (obj.has("positionMs")) obj.getLong("positionMs") else null),
        "durationMs" to (if (obj.has("durationMs")) obj.getLong("durationMs") else null),
        "playbackCompleted" to obj.optBoolean("playbackCompleted", false),
        "playbackError" to obj.optBoolean("playbackError", false)
      )
    } catch (error: org.json.JSONException) {
      android.util.Log.w("ExternalPlayerChannel", "Dropping an unreadable orphaned player result", error)
      null
    }
  }

  /** The Zidoo player activities installed here, most current first. */
  private fun zidooPlayerComponents(): List<String> = listOf(ZIDOO_PLAYER_COMPONENT, ZIDOO_LEGACY_PLAYER_COMPONENT).filter { component ->
    isZidooComponent(component, android.os.Build.MANUFACTURER) && activityExists(component)
  }

  private fun activityExists(component: String): Boolean {
    val name = ComponentName.unflattenFromString(component) ?: return false
    return try {
      activity.packageManager.getActivityInfo(name, 0)
      true
    } catch (_: PackageManager.NameNotFoundException) {
      false
    }
  }

  fun dispose() {
    if (pendingResult != null) ExternalPlaybackService.stop(activity)
    pendingResult?.error("ACTIVITY_DESTROYED", "Activity was destroyed while external player was active", null)
    pendingResult = null
  }

  internal fun buildResult(resultCode: Int, data: Intent?): Map<String, Any?> {
    val extras = data?.extras
    val endPosition = firstNumberExtra(extras, positionExtras)
    val duration = firstNumberExtra(extras, durationExtras)
    val action = data?.action
    val playbackCompleted = when (action) {
      API_MX_RESULT_ID -> extras?.getString(API_MX_RESULT_END_BY) == API_MX_RESULT_END_BY_PLAYBACK_COMPLETION
      API_VIMU_RESULT_ID -> resultCode == API_VIMU_RESULT_PLAYBACK_COMPLETED
      else -> false
    }
    val playbackError = action == API_VIMU_RESULT_ID && resultCode == API_VIMU_RESULT_ERROR

    return mapOf(
      "launched" to true,
      "resultCode" to resultCode,
      "resultOk" to (resultCode == Activity.RESULT_OK),
      "action" to action,
      "positionMs" to endPosition,
      "durationMs" to duration,
      "playbackCompleted" to playbackCompleted,
      "playbackError" to playbackError
    )
  }

  private fun firstNumberExtra(extras: Bundle?, keys: Array<String>): Long? {
    if (extras == null) return null
    for (key in keys) {
      @Suppress("DEPRECATION")
      val value = extras.get(key)
      when (value) {
        is Number -> return value.toLong()
        is String -> value.toLongOrNull()?.let { return it }
      }
    }
    return null
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "openVideo" -> openVideo(call, result)
      "zidooPlayerComponents" -> result.success(zidooPlayerComponents())
      "takeOrphanedResult" -> result.success(takeOrphanedResult())
      else -> result.notImplemented()
    }
  }

  @Suppress("UNCHECKED_CAST")
  private fun openVideo(call: MethodCall, result: MethodChannel.Result) {
    val filePath = call.argument<String>("filePath")
    val packageNames = call.argument<List<Any?>>("packages")
      ?.mapNotNull { (it as? String)?.trim()?.takeIf(String::isNotEmpty) }
      ?: emptyList()
    val components = call.argument<List<Any?>>("components")
      ?.mapNotNull { (it as? String)?.let(ComponentName::unflattenFromString) }
      ?: emptyList()
    val title = call.argument<String>("title")?.trim()?.takeIf(String::isNotEmpty)
    val startPositionMs = call.argument<Number>("startPositionMs")?.toLong() ?: 0L
    val subtitleArguments = call.argument<List<Any?>>("subtitles") ?: emptyList()
    val trackIndexes = TrackIndexes(
      audio = call.argument<Number>("audioIndex")?.toInt(),
      subtitle = call.argument<Number>("subtitleIndex")?.toInt()
    )
    val session = call.argument<String>("session")
    val keepAlive = call.argument<Boolean>("keepAlive") == true
    val directFile = call.argument<Boolean>("directFile") == true

    if (filePath == null) {
      result.error("INVALID_ARGUMENT", "filePath is required", null)
      return
    }
    if (pendingResult != null) {
      result.error("ALREADY_ACTIVE", "An external player is already active", null)
      return
    }

    try {
      val source = if (directFile) directSource(filePath) else resolveSource(filePath)
      val subtitles = subtitleArguments.mapNotNull(::resolveSubtitle)
      val targets = buildList {
        components.forEach { add(LaunchTarget(component = it)) }
        packageNames.forEach { add(LaunchTarget(packageName = it)) }
        if (isEmpty()) add(LaunchTarget())
      }
      // A stale session from a launch whose result never came is replaced
      // either way: only the launch below can be answered now.
      val editor = prefs().edit()
      if (session == null) editor.remove(KEY_PENDING_SESSION) else editor.putString(KEY_PENDING_SESSION, session)
      editor.commit()
      // Started before the player covers Plezy: a foreground service may
      // not be started from the background on newer Android versions.
      if (keepAlive) ExternalPlaybackService.start(activity, title)
      for (target in targets) {
        try {
          pendingResult = result
          val intent =
            buildIntent(source, target.packageName, startPositionMs, title, subtitles, target.component, trackIndexes)
          withFileUrisAllowed(source.uri.scheme == "file") { activity.startActivityForResult(intent, REQUEST_CODE) }
          return
        } catch (_: ActivityNotFoundException) {
          pendingResult = null
        }
      }
      prefs().edit().remove(KEY_PENDING_SESSION).apply()
      if (keepAlive) ExternalPlaybackService.stop(activity)

      val message = if (components.isEmpty() && packageNames.isEmpty()) {
        "No app found for video"
      } else {
        "No app found for: ${(components.map { it.flattenToShortString() } + packageNames).joinToString(", ")}"
      }
      result.error("APP_NOT_FOUND", message, null)
    } catch (error: Exception) {
      pendingResult = null
      if (keepAlive) ExternalPlaybackService.stop(activity)
      result.error("LAUNCH_FAILED", error.message ?: error.javaClass.simpleName, null)
    }
  }

  internal data class Source(val uri: Uri, val grantRead: Boolean, val fileName: String?)

  internal data class Subtitle(val source: Source, val name: String?, val enabled: Boolean)

  internal data class TrackIndexes(val audio: Int? = null, val subtitle: Int? = null)

  private data class LaunchTarget(val packageName: String? = null, val component: ComponentName? = null)

  private fun resolveSource(filePath: String): Source {
    if (filePath.startsWith("http://") || filePath.startsWith("https://")) {
      val uri = Uri.parse(filePath)
      return Source(uri, grantRead = false, fileName = uri.lastPathSegment)
    }
    if (filePath.startsWith("content://")) {
      val uri = Uri.parse(filePath)
      return Source(uri, grantRead = true, fileName = uri.lastPathSegment)
    }

    val path = if (filePath.startsWith("file://")) filePath.removePrefix("file://") else filePath
    val file = File(path)
    val uri = FileProvider.getUriForFile(activity, "com.edde746.plezy.fileprovider", file)
    return Source(uri, grantRead = true, fileName = file.name)
  }

  // A file the player reads in place, from a share the box mounts itself
  // (`/mnt/smb/…`) or by a network URL it opens itself (`smb://`, `nfs://`).
  // Plezy may not be able to read it, so no content URI can stand in.
  internal fun directSource(filePath: String): Source {
    if (filePath.startsWith("/")) {
      val file = File(filePath)
      return Source(Uri.fromFile(file), grantRead = false, fileName = file.name)
    }
    val uri = Uri.parse(filePath)
    return Source(uri, grantRead = false, fileName = uri.lastPathSegment)
  }

  // Android refuses to hand another app a `file://` URI from an app that
  // targets Android 7 or later. The native Zidoo player opens share mounts
  // only that way, so the check is off for that one launch.
  private inline fun withFileUrisAllowed(allowed: Boolean, launch: () -> Unit) {
    if (!allowed) return launch()
    val policy = StrictMode.getVmPolicy()
    StrictMode.setVmPolicy(StrictMode.VmPolicy.Builder().build())
    try {
      launch()
    } finally {
      StrictMode.setVmPolicy(policy)
    }
  }

  private fun resolveSubtitle(argument: Any?): Subtitle? {
    val map = argument as? Map<*, *> ?: return null
    val location = (map["uri"] as? String)?.takeIf(String::isNotEmpty) ?: return null
    val source = try {
      resolveSource(location)
    } catch (error: IllegalArgumentException) {
      // FileProvider refuses a path outside its roots. Losing one subtitle
      // must not cost the whole launch.
      android.util.Log.w("ExternalPlayerChannel", "Skipping a subtitle FileProvider cannot share", error)
      return null
    }
    val name = (map["name"] as? String)?.trim()?.takeIf(String::isNotEmpty)
    return Subtitle(source, name, enabled = map["enabled"] == true)
  }

  internal fun buildIntent(
    source: Source,
    packageName: String?,
    startPositionMs: Long,
    title: String?,
    subtitles: List<Subtitle> = emptyList(),
    component: ComponentName? = null,
    trackIndexes: TrackIndexes = TrackIndexes()
  ): Intent = Intent(Intent.ACTION_VIEW).apply {
    setDataAndType(source.uri, "video/*")
    if (source.grantRead) addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    packageName?.let(::setPackage)
    component?.let(::setComponent)
    trackIndexes.audio?.takeIf { it >= 0 }?.let { putExtra(API_ZIDOO_AUDIO_INDEX, it) }
    trackIndexes.subtitle?.takeIf { it >= 1 }?.let { putExtra(API_ZIDOO_SUBTITLE_INDEX, it) }
    val startPosition = startPositionMs.coerceAtLeast(0).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    if (startPosition > 0) {
      putExtra(API_MX_RESULT_POSITION, startPosition)
      putExtra(API_VIMU_SEEK_POSITION, startPosition)
      putExtra(API_VLC_FROM_START, false)
    } else {
      putExtra(API_VLC_FROM_START, true)
    }
    putExtra(API_MX_RETURN_RESULT, true)
    putExtra(API_MX_SECURE_URI, true)
    putExtra(API_VIMU_RESUME, false)
    title?.let {
      putExtra(API_MX_TITLE, it)
      putExtra(API_VIMU_TITLE, it)
    }
    source.fileName?.let { putExtra(API_MX_FILENAME, it) }
    if (subtitles.isNotEmpty()) {
      putExtra(API_SUBS, Array<Parcelable>(subtitles.size) { subtitles[it].source.uri })
      putExtra(API_SUBS_NAME, Array(subtitles.size) { subtitles[it].name ?: subtitles[it].source.fileName.orEmpty() })
      putExtra(API_SUBS_FILENAME, Array(subtitles.size) { subtitles[it].source.fileName.orEmpty() })
      putExtra(API_SUBS_ENABLE, subtitles.filter { it.enabled }.map<Subtitle, Parcelable> { it.source.uri }.toTypedArray())
      // FLAG_GRANT_READ_URI_PERMISSION reaches the data URI and ClipData,
      // never extras: a downloaded sidecar's content:// URI has to ride in
      // ClipData too, or the player is refused when it opens the file.
      val shared = subtitles.filter { it.source.grantRead }.map { it.source.uri }
      if (shared.isNotEmpty()) {
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        clipData = ClipData.newRawUri(null, shared.first()).apply {
          shared.drop(1).forEach { addItem(ClipData.Item(it)) }
        }
      }
    }
  }
}
