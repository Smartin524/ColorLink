package com.colorlink

import android.content.Context

/** 总开关的唯一入口：配对和权限保留，所有自动唤醒入口遵守同一个持久化状态。 */
object ConnectionControl {
    fun setEnabled(ctx: Context, enabled: Boolean) {
        Prefs.setConnectionEnabled(ctx, enabled)
        refresh(ctx)
    }

    fun refresh(ctx: Context) {
        if (Prefs.connectionEnabled(ctx)) {
            LinkCore.start(ctx)
            BleWake.update(ctx)
            LinkService.refresh(ctx)
            NotifyListener.rebindIfNeeded(ctx)
        } else {
            Watchdog.cancel(ctx)
            BleWake.update(ctx)
            LinkCore.stop()
            LinkService.stop(ctx)
            NotifyListener.pause()
        }
    }
}
