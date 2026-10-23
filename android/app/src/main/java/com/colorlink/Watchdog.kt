package com.colorlink

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context

private const val TAG = "ColorLink.Watchdog"

/**
 * 兜底：连着 Wi-Fi 时大约每 15 分钟由系统叫醒一次，ColorLink 没在运行就把它拉起来。
 *
 * 任务登记在系统的任务调度里，进程被杀后照样有效，开机后也还在（setPersisted）。
 * 通知监听、前台服务、蓝牙唤醒都失效时（例如在 Mac 不在的网络里被杀、回家后蓝牙又没在扫），靠它恢复。
 * ColorLink 本来就在运行时只是看一眼，几乎不耗电。
 */
class Watchdog : JobService() {
    companion object {
        private const val JOB_ID = 1001

        /** 登记一次即可；已经登记过就不动 */
        fun schedule(ctx: Context) {
            val js = ctx.getSystemService(JobScheduler::class.java)
            if (js.getPendingJob(JOB_ID) != null) return
            val job = JobInfo.Builder(JOB_ID, ComponentName(ctx, Watchdog::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_UNMETERED)
                .setPeriodic(15 * 60_000L)
                .setPersisted(true)
                .build()
            val ok = js.schedule(job) == JobScheduler.RESULT_SUCCESS
            AppLog.i(TAG, if (ok) "已登记定时检查（连着 Wi-Fi 时约每 15 分钟）" else "登记定时检查失败")
        }
    }

    override fun onStartJob(params: JobParameters?): Boolean {
        AppLog.init(this)
        if (!LinkCore.running) {
            AppLog.i(TAG, "定时检查：ColorLink 没在运行，重新启动")
            LinkCore.start(this)
            LinkService.refresh(this)
        }
        BleWake.update(this)
        NotifyListener.rebindIfNeeded(this)
        return false
    }

    override fun onStopJob(params: JobParameters?) = false
}
