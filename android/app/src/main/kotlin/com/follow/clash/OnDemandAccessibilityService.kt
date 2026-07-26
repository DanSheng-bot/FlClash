package com.follow.clash

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import com.follow.clash.common.GlobalState
import kotlinx.coroutines.launch

class OnDemandAccessibilityService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var lastPackageName: String? = null
    private var isTimerRunning = false

    private val resumeRunnable = Runnable {
        isTimerRunning = false
        GlobalState.launch {
            ServiceState.resume()
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        updateServiceConfig()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val packageName = event.packageName?.toString() ?: return
        if (packageName == GlobalState.application.packageName) return
        
        // 如果是同一个包名重复触发，且不是黑名单包，则忽略以节省性能
        val onDemandPackages = ServiceState.onDemandPackages
        val isBlacklisted = onDemandPackages.contains(packageName)
        if (packageName == lastPackageName && !isBlacklisted) return
        
        lastPackageName = packageName

        if (isBlacklisted) {
            // 进入黑名单应用：取消恢复计时器，执行暂停
            if (isTimerRunning) {
                handler.removeCallbacks(resumeRunnable)
                isTimerRunning = false
            }
            GlobalState.launch {
                ServiceState.suspend()
            }
        } else {
            // 进入普通应用：如果之前没在计时，则启动 1 分钟计时器
            // 注意：不要在普通应用间切换时重复重置计时器，保证恢复时间的准确性
            if (!isTimerRunning) {
                isTimerRunning = true
                handler.postDelayed(resumeRunnable, 60 * 1000L)
            }
        }
    }

    override fun onInterrupt() {}

    fun updateServiceConfig() {
        val info = serviceInfo ?: AccessibilityServiceInfo()
        val onDemandPackages = ServiceState.onDemandPackages
        
        if (onDemandPackages.isEmpty()) {
            // 名单为空时，仅监听自身包名，相当于进入静默状态
            info.packageNames = arrayOf(GlobalState.application.packageName)
        } else {
            // 名单不为空时，必须监听全局（null）才能捕获“退出黑名单”的动作
            info.packageNames = null
        }
        
        serviceInfo = info
    }

    companion object {
        private var instance: OnDemandAccessibilityService? = null

        fun updateConfig() {
            instance?.updateServiceConfig()
        }
    }
}
