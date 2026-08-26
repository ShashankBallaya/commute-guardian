package com.ballshank.commute_guardian

import android.content.ComponentName
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the wake escalation's earphone-tap acknowledgment (W1 spike).
 *
 * While a wake ladder is live, Dart asks for a MediaSessionCompat that reports
 * itself as playing. Android routes media buttons (earphone tap, TWS tap,
 * inline click) to the most recently active playing session, and the looping
 * alarm tone makes that claim honest. Every media key, whatever it is, means
 * "I'm awake" and is forwarded to Dart; the session is released the moment
 * the ladder stands down so the rider's taps go back to their music app.
 *
 * Best-effort by design: the session dies with this activity, so a tap after
 * the OS reclaims the backgrounded activity is lost. The escalation itself
 * plus the on-screen dismiss are the guaranteed fallback.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var session: MediaSessionCompat? = null
    private var nowPlayingClaim: AudioTrack? = null

    private companion object {
        val MEDIA_KEY_CODES = setOf(
            KeyEvent.KEYCODE_HEADSETHOOK,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_STOP,
            KeyEvent.KEYCODE_MEDIA_NEXT,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "commute_guardian/media_ack",
        )
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "startSession" -> {
                    startSession()
                    result.success(null)
                }
                "stopSession" -> {
                    stopSession()
                    result.success(null)
                }
                "getAlarmVolume" -> result.success(alarmVolume())
                else -> result.notImplemented()
            }
        }
        channel = ch

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "commute_guardian/oem",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "describe" -> result.success(
                    mapOf(
                        "manufacturer" to Build.MANUFACTURER,
                        "brand" to Build.BRAND,
                        "model" to Build.MODEL,
                        "sdkInt" to Build.VERSION.SDK_INT,
                    ),
                )
                "openAutoStart" -> result.success(openAutoStart())
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Opens the OEM screen that holds the second permission, and reports which
     * one opened.
     *
     * RESOLVED BEFORE IT IS STARTED, every time. These components differ by
     * skin version and several of them are not exported on newer builds, so
     * starting one blind throws ActivityNotFoundException or SecurityException
     * on exactly the phones this exists for. Returns null when nothing here
     * matches, which the Dart side reads as "show the steps and no button":
     * a button that does nothing is worse than no button.
     */
    private fun openAutoStart(): String? {
        for ((pkg, cls) in AUTOSTART_TARGETS) {
            val intent = Intent().apply {
                component = ComponentName(pkg, cls)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (packageManager.resolveActivity(intent, 0) == null) continue
            try {
                startActivity(intent)
                return "$pkg/$cls"
            } catch (e: Exception) {
                // Resolvable and still refused, which happens on skins that
                // export the component to the system only. Try the next one.
                continue
            }
        }
        return null
    }

    /**
     * How loud the wake alarm will actually be, 0.0 to 1.0, or null when the
     * platform will not say.
     *
     * STREAM_ALARM, not STREAM_MUSIC, and the difference is the whole point.
     * The ladder tone is played with AndroidUsageType.alarm (see
     * wake_alert_output.dart), so it rides the alarm stream and the rider's
     * media slider cannot touch it. Reading the media volume here would report
     * a number that has nothing to do with whether the alarm can be heard, and
     * would warn or reassure for the wrong reason.
     *
     * Null rather than a guess on failure: the Dart gateway fails open, so an
     * unreadable volume shows the rider nothing rather than a warning we
     * cannot stand behind.
     */
    private fun alarmVolume(): Double? {
        return try {
            val audio = getSystemService(AUDIO_SERVICE) as AudioManager
            val max = audio.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            if (max <= 0) return null
            audio.getStreamVolume(AudioManager.STREAM_ALARM).toDouble() / max
        } catch (e: Exception) {
            null
        }
    }

    private fun startSession() {
        if (session != null) return
        val s = MediaSessionCompat(this, "CommuteGuardianWakeAck")
        s.setCallback(object : MediaSessionCompat.Callback() {
            override fun onMediaButtonEvent(mediaButtonEvent: Intent): Boolean {
                @Suppress("DEPRECATION")
                val key = mediaButtonEvent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
                if (key != null && key.action == KeyEvent.ACTION_DOWN) {
                    channel?.invokeMethod("ack", key.keyCode)
                }
                // Consumed either way: while the ladder is live no media key
                // should leak through to another app.
                return true
            }
        })
        s.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY
                        or PlaybackStateCompat.ACTION_PAUSE
                        or PlaybackStateCompat.ACTION_PLAY_PAUSE
                        or PlaybackStateCompat.ACTION_STOP
                        or PlaybackStateCompat.ACTION_SKIP_TO_NEXT
                        or PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS,
                )
                .setState(PlaybackStateCompat.STATE_PLAYING, 0L, 1.0f)
                .build(),
        )
        s.isActive = true
        session = s
        startNowPlayingClaim()
    }

    private fun stopSession() {
        session?.let {
            it.isActive = false
            it.release()
        }
        session = null
        nowPlayingClaim?.let {
            it.stop()
            it.release()
        }
        nowPlayingClaim = null
    }

    /**
     * Android 9 routes media keys to the session of the uid it believes is
     * actively playing audio, and it never believes us: the ladder tone plays
     * through a player that does not register with AudioService (observed on
     * the 3T, 15 Jul bench), and the check-in window is deliberately silent.
     * A looping, muted, media-usage AudioTrack keeps the uid "playing" for the
     * whole life of the session, which is what makes the session's
     * STATE_PLAYING claim real to the button router. No audio focus is taken;
     * the rider's music is untouched.
     */
    private fun startNowPlayingClaim() {
        if (nowPlayingClaim != null) return
        val sampleRate = 8000
        val silence = ByteArray(sampleRate * 2) // one second, 16-bit mono
        val track = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build(),
            AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(sampleRate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build(),
            silence.size,
            AudioTrack.MODE_STATIC,
            AudioManager.AUDIO_SESSION_ID_GENERATE,
        )
        track.write(silence, 0, silence.size)
        track.setLoopPoints(0, sampleRate, -1)
        track.setVolume(0f)
        track.play()
        nowPlayingClaim = track
    }

    /**
     * While the activity itself is focused (bench runs, rider looking at the
     * screen), a media key is delivered to this window before the media
     * session service ever sees it, so catch it here too. Locked-screen and
     * backgrounded delivery still comes through the session callback.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (session != null &&
            event.action == KeyEvent.ACTION_DOWN &&
            event.keyCode in MEDIA_KEY_CODES
        ) {
            channel?.invokeMethod("ack", event.keyCode)
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        stopSession()
        super.onDestroy()
    }
}

/**
 * The phone's own name for itself, and the OEM settings screen that decides
 * whether this app is allowed to keep running.
 *
 * WHY THIS EXISTS. OEM battery killers are this project's named top product
 * risk. Android's own battery-optimisation exemption is already requested and
 * already reported in Settings, and on a Xiaomi, Oppo, Vivo, Realme, OnePlus,
 * Samsung or Huawei phone it is NOT ENOUGH: those skins carry a second,
 * separate list (autostart, auto launch, background usage limits) with no
 * public API, no way to read it, and no way to change it from code. A ride can
 * die on a phone that reports every permission green.
 *
 * WHAT THIS CAN AND CANNOT DO. It can name the phone, and it can OPEN the
 * screen the rider has to change. It cannot read the setting, cannot set it,
 * and must never be built on as though it could. That is why the Dart side
 * offers steps and an acknowledgement rather than a status row: a row that can
 * never go green is the one thing the readiness card refuses to draw.
 *
 * The component names are the dontkillmyapp.com patterns. They are tried in
 * order and every one is resolved against the package manager first, because
 * an unresolvable component throws and these differ by skin version.
 */
private val AUTOSTART_TARGETS = listOf(
    // Xiaomi, Redmi, POCO (MIUI and HyperOS)
    "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
    // Oppo and Realme (ColorOS), newest package first
    "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
    "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
    "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity",
    // Vivo (Funtouch and OriginOS)
    "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
    "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
    // Huawei and Honor (EMUI and MagicOS)
    "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
    "com.huawei.systemmanager" to "com.huawei.systemmanager.optimize.process.ProtectActivity",
    // OnePlus (OxygenOS)
    "com.oneplus.security" to "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
    // Samsung (One UI). No autostart list, so this opens Device care's battery
    // screen, which is where Sleeping apps lives.
    "com.samsung.android.lool" to "com.samsung.android.sm.ui.battery.BatteryActivity",
)
