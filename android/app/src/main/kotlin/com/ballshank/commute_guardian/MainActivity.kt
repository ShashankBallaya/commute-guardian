package com.ballshank.commute_guardian

import android.content.Intent
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
                else -> result.notImplemented()
            }
        }
        channel = ch
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
    }

    private fun stopSession() {
        session?.let {
            it.isActive = false
            it.release()
        }
        session = null
    }

    override fun onDestroy() {
        stopSession()
        super.onDestroy()
    }
}
