package com.follow.clash.service.modules

import android.app.Notification.FOREGROUND_SERVICE_IMMEDIATE
import android.app.NotificationManager
import android.app.Service
import android.app.Service.STOP_FOREGROUND_REMOVE
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.getSystemService
import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState
import com.follow.clash.common.QuickAction
import com.follow.clash.common.quickIntent
import com.follow.clash.common.receiveBroadcastFlow
import com.follow.clash.common.startForeground
import com.follow.clash.common.toPendingIntent
import com.follow.clash.core.Core
import com.follow.clash.service.R
import com.follow.clash.service.ServiceConfig
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.getSpeedTrafficText
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.launch

private const val STOP_TRACE = "[STOP-TRACE]"
private val NOTIFICATION_CHECK_DELAYS = longArrayOf(0L, 250L, 1_000L, 3_000L)

private data class ExtendedNotificationParams(
    val title: String,
    val stopText: String,
    val contentText: String,
)

private fun NotificationParams.extended(service: Service) =
    ExtendedNotificationParams(
        title,
        service.getString(R.string.stop),
        when {
            isSuspended -> service.getString(R.string.vpn_paused_on_demand)
            networkSpeedNotification -> Core.getSpeedTrafficText(onlyStatisticsProxy)
            else -> service.getString(R.string.connected)
        },
    )

internal class NotificationModule(
    private val service: Service,
    private val scope: CoroutineScope,
) : ServiceModule {
    override fun start() {
        val initialParams = ServiceConfig.notificationParams.value.extended(service)
        update(initialParams)
        scope.launch {
            var displayedParams = initialParams
            val screenFlow = service.receiveBroadcastFlow {
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_SCREEN_OFF)
            }.map { intent ->
                intent.action == Intent.ACTION_SCREEN_ON
            }.onStart {
                emit(isScreenOn())
            }

            combine(
                ServiceConfig.notificationParams,
                screenFlow,
            ) { params, screenOn ->
                params to screenOn
            }.collectLatest { (params, screenOn) ->
                if (!screenOn) return@collectLatest

                if (!params.networkSpeedNotification || params.isSuspended) {
                    val nextParams = params.extended(service)
                    if (nextParams != displayedParams) {
                        update(nextParams)
                        displayedParams = nextParams
                    }
                    return@collectLatest
                }

                while (true) {
                    delay(1_000)
                    val nextParams = params.extended(service)
                    if (nextParams != displayedParams) {
                        update(nextParams)
                        displayedParams = nextParams
                    }
                }
            }
        }
    }

    private fun isScreenOn() =
        service.getSystemService<PowerManager>()?.isInteractive ?: true

    private val notificationBuilder: NotificationCompat.Builder by lazy {
        val intent = Intent().setComponent(Components.mainActivity)

        NotificationCompat.Builder(
            service,
            GlobalState.NOTIFICATION_CHANNEL,
        ).apply {
            setSmallIcon(R.drawable.ic_service)
            setContentTitle("FlClash")
            setContentIntent(intent.toPendingIntent)
            setPriority(NotificationCompat.PRIORITY_LOW)
            setCategory(NotificationCompat.CATEGORY_SERVICE)
            setOngoing(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                foregroundServiceBehavior = FOREGROUND_SERVICE_IMMEDIATE
            }
            setShowWhen(true)
            setOnlyAlertOnce(true)
        }
    }

    private fun update(params: ExtendedNotificationParams) {
        service.startForeground(
            with(notificationBuilder) {
                setContentTitle(params.title)
                setContentText(params.contentText)
                clearActions()
                addAction(
                    0,
                    params.stopText,
                    QuickAction.STOP.quickIntent.toPendingIntent,
                ).build()
            },
        )
    }

    @Suppress("DEPRECATION")
    override fun stop() {
        val startedAt = SystemClock.elapsedRealtime()
        GlobalState.log(
            "$STOP_TRACE stopForeground begin sdk=${Build.VERSION.SDK_INT}",
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            service.stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            service.stopForeground(true)
        }
        GlobalState.log(
            "$STOP_TRACE stopForeground returned in " +
                "${SystemClock.elapsedRealtime() - startedAt}ms",
        )
        traceNotificationRemoval(startedAt)
    }

    private fun traceNotificationRemoval(stopStartedAt: Long) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val notificationManager = service.getSystemService<NotificationManager>()
        if (notificationManager == null) {
            GlobalState.log("$STOP_TRACE NotificationManager is unavailable")
            return
        }
        val handler = Handler(Looper.getMainLooper())
        NOTIFICATION_CHECK_DELAYS.forEach { delayMillis ->
            handler.postDelayed(
                {
                    val actualElapsed = SystemClock.elapsedRealtime() - stopStartedAt
                    runCatching {
                        notificationManager.activeNotifications.any { notification ->
                            notification.id == GlobalState.NOTIFICATION_ID
                        }
                    }.onSuccess { active ->
                        GlobalState.log(
                            "$STOP_TRACE notification check scheduled=${delayMillis}ms " +
                                "actual=${actualElapsed}ms active=$active",
                        )
                    }.onFailure { error ->
                        GlobalState.log(
                            "$STOP_TRACE notification check failed " +
                                "scheduled=${delayMillis}ms actual=${actualElapsed}ms: $error",
                        )
                    }
                },
                delayMillis,
            )
        }
    }
}
