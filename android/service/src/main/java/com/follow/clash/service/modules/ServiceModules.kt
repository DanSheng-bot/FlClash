package com.follow.clash.service.modules

import android.app.Service
import android.os.SystemClock
import com.follow.clash.common.GlobalState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

private const val STOP_TRACE = "[STOP-TRACE]"

internal interface ServiceModule {
    fun start()

    fun stop()
}

internal class ServiceModules(private val service: Service) {
    private var scope: CoroutineScope? = null
    private var modules = emptyList<ServiceModule>()

    @Synchronized
    fun start() {
        if (scope != null) return

        val nextScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val nextModules = listOf(
            NotificationModule(service, nextScope),
            NetworkObserveModule(service),
            SuspendModule(service, nextScope),
        )
        val startedModules = mutableListOf<ServiceModule>()

        try {
            nextModules.forEach { module ->
                module.start()
                startedModules.add(module)
            }
            scope = nextScope
            modules = nextModules
        } catch (error: Throwable) {
            nextScope.cancel()
            startedModules.asReversed().forEach { module ->
                runCatching { module.stop() }
            }
            throw error
        }
    }

    fun stop() {
        val requestedAt = SystemClock.elapsedRealtime()
        GlobalState.log(
            "$STOP_TRACE ServiceModules.stop waiting for monitor " +
                "service=${service.javaClass.simpleName}",
        )
        synchronized(this) {
            val startedAt = SystemClock.elapsedRealtime()
            GlobalState.log(
                "$STOP_TRACE ServiceModules monitor acquired in " +
                    "${startedAt - requestedAt}ms",
            )
            val currentScope = scope
            if (currentScope == null) {
                GlobalState.log("$STOP_TRACE ServiceModules.stop has no active modules")
                return
            }
            val currentModules = modules
            scope = null
            modules = emptyList()

            currentScope.cancel()
            GlobalState.log(
                "$STOP_TRACE ServiceModules scope cancelled; " +
                    "stopping ${currentModules.size} modules",
            )
            currentModules.asReversed().forEach { module ->
                val moduleStartedAt = SystemClock.elapsedRealtime()
                runCatching { module.stop() }
                    .onSuccess {
                        GlobalState.log(
                            "$STOP_TRACE ${module.javaClass.simpleName}.stop completed in " +
                                "${SystemClock.elapsedRealtime() - moduleStartedAt}ms",
                        )
                    }
                    .onFailure { error ->
                        GlobalState.log(
                            "$STOP_TRACE ${module.javaClass.simpleName}.stop failed after " +
                                "${SystemClock.elapsedRealtime() - moduleStartedAt}ms: $error",
                        )
                    }
            }
            GlobalState.log(
                "$STOP_TRACE ServiceModules.stop completed in " +
                    "${SystemClock.elapsedRealtime() - startedAt}ms",
            )
        }
    }
}
