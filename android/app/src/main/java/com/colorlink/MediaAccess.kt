package com.colorlink

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager

/** 每次读取当前授权状态；不缓存，用户可以在系统设置里随时收窄权限。 */
object MediaAccess {
    fun fullVisual(ctx: Context) =
        granted(ctx, Manifest.permission.READ_MEDIA_IMAGES) && granted(ctx, Manifest.permission.READ_MEDIA_VIDEO)

    private fun granted(ctx: Context, permission: String) =
        ctx.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    fun full(ctx: Context, kind: MediaRepo.Kind): Boolean {
        val permission = when (kind) {
            MediaRepo.Kind.IMAGE -> Manifest.permission.READ_MEDIA_IMAGES
            MediaRepo.Kind.VIDEO -> Manifest.permission.READ_MEDIA_VIDEO
            MediaRepo.Kind.AUDIO -> Manifest.permission.READ_MEDIA_AUDIO
        }
        return granted(ctx, permission)
    }
}
