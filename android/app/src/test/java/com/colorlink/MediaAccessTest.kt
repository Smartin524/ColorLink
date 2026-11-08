package com.colorlink

import android.Manifest
import android.content.ContextWrapper
import android.content.pm.PackageManager
import org.junit.Assert.*
import org.junit.Test

class MediaAccessTest {
    private class Permissions : ContextWrapper(null) {
        val allowed = mutableSetOf<String>()
        override fun checkSelfPermission(permission: String) =
            if (permission in allowed) PackageManager.PERMISSION_GRANTED else PackageManager.PERMISSION_DENIED
    }

    @Test fun fullAccessRequiresBothImagesAndVideo() {
        val ctx = Permissions()
        assertFalse(MediaAccess.fullVisual(ctx))
        ctx.allowed += Manifest.permission.READ_MEDIA_IMAGES
        assertFalse(MediaAccess.fullVisual(ctx))
        ctx.allowed += Manifest.permission.READ_MEDIA_VIDEO
        assertTrue(MediaAccess.fullVisual(ctx))
        ctx.allowed -= Manifest.permission.READ_MEDIA_IMAGES
        assertFalse(MediaAccess.fullVisual(ctx))
    }

    @Test fun selectedAccessIsNotFullAndRevocationIsObservedImmediately() {
        val ctx = Permissions()
        ctx.allowed += Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
        assertFalse(MediaAccess.fullVisual(ctx))
        ctx.allowed += listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        assertTrue(MediaAccess.fullVisual(ctx))
        ctx.allowed -= Manifest.permission.READ_MEDIA_VIDEO
        assertFalse(MediaAccess.fullVisual(ctx))
    }
}
