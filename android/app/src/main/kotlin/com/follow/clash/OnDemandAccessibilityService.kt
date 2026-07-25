package com.follow.clash

import android.accessibilityservice.AccessibilityService
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import com.follow.clash.common.GlobalState
import kotlinx.coroutines.launch

class OnDemandAccessibilityService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var lastPackageName: String? = null
    private val resumeRunnable = Runnable {
        GlobalState.launch {
            ServiceState.resume()
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val packageName = event.packageName?.toString() ?: return
        if (packageName == GlobalState.application.packageName) return
        if (packageName == lastPackageName) return
        lastPackageName = packageName

        val onDemandPackages = ServiceState.onDemandPackages
        if (onDemandPackages.contains(packageName)) {
            handler.removeCallbacks(resumeRunnable)
            GlobalState.launch {
                ServiceState.suspend()
            }
        } else {
            handler.removeCallbacks(resumeRunnable)
            handler.postDelayed(resumeRunnable, 60 * 1000L) // 1 minute
        }
    }

    override fun onInterrupt() {}
}
