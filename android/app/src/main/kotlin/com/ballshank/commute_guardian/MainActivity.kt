package com.ballshank.commute_guardian

import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
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
