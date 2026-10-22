package com.colorlink

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PathMeasure
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.Shader
import android.view.View
import android.view.animation.PathInterpolator
import kotlin.math.sin

/**
 * 首页的链环标志，用代码实时绘制（几何和 tools/make-icons.swift 一致，扣合状态就是图标本身）。
 *
 * - 连上：蓝环沿轮廓长出 → 青环紧跟着长出 → 交叉处细缝张开、扣在一起 → 轻轻回弹
 * - 断开：细缝合上（解扣）→ 两个环向两边分开，同时褪成灰色
 * - 待命（没连接）：静止的、分开的两个灰色链环
 *
 * 只在动画播放的一秒多里逐帧重绘，静止时不耗电。
 */
class LinkLogoView(context: Context) : View(context) {

    // 1024 画布里的几何（旋转前）
    private val capsuleW = 440f
    private val capsuleH = 240f
    private val stroke = 56f
    private val gap = 22f
    private val crossingRadius = 92f
    /** 分开时每个环沿长轴移开的距离 */
    private val separation = 78f

    private val pathA = capsule(352f, 512f)
    private val pathB = capsule(672f, 512f)
    private val lenA = PathMeasure(pathA, true).length
    private val lenB = PathMeasure(pathB, true).length
    private val segment = Path()
    private val crossTop = Path().apply { addCircle(512f, 408f, crossingRadius, Path.Direction.CW) }
    private val crossBottom = Path().apply { addCircle(512f, 616f, crossingRadius, Path.Direction.CW) }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = stroke
        strokeCap = Paint.Cap.ROUND
    }
    private val clear = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
    }
    private val blue = LinearGradient(132f, 392f, 572f, 632f, intArrayOf(0xFF2EAEFC.toInt(), 0xFF006DFF.toInt(), 0xFF0042CB.toInt()), null, Shader.TileMode.CLAMP)
    private val cyan = LinearGradient(452f, 392f, 892f, 632f, intArrayOf(0xFF6FEFFA.toInt(), 0xFF00CEF0.toInt(), 0xFF00A6E2.toInt()), null, Shader.TileMode.CLAMP)
    private val grayA = LinearGradient(132f, 392f, 572f, 632f, 0xFFC4C6CC.toInt(), 0xFFA9ACB3.toInt(), Shader.TileMode.CLAMP)
    private val grayB = LinearGradient(452f, 392f, 892f, 632f, 0xFFD3D5DA.toInt(), 0xFFB8BBC1.toInt(), Shader.TileMode.CLAMP)

    // 当前画面的参数，动画就是在改它们
    private var growA = 1f
    private var growB = 1f
    private var lock = 0f // 交叉处细缝张开的程度：0 未扣合，1 扣合
    private var apart = 1f // 两个环分开的程度：0 并在一起，1 完全分开
    private var gray = 1f // 0 彩色，1 灰色
    private var bounce = 1f

    private var animator: ValueAnimator? = null

    /** 连上：从无到有长出并扣合 */
    fun playConnect() = animate(1400, PathInterpolator(0.25f, 0.1f, 0.25f, 1f)) { t ->
        growA = phase(t, 0f, 0.55f)
        growB = phase(t, 0.25f, 0.8f)
        lock = phase(t, 0.75f, 1f)
        apart = 0f
        gray = 0f
        bounce = if (lock in 0f..0.999f) 1f + 0.06f * sin(lock * Math.PI).toFloat() else 1f
    }

    /** 断开：先解扣，再向两边分开并褪成灰色 */
    fun playDisconnect() = animate(900, PathInterpolator(0.4f, 0f, 0.2f, 1f)) { t ->
        growA = 1f
        growB = 1f
        lock = 1f - phase(t, 0f, 0.3f)
        apart = phase(t, 0.25f, 1f)
        gray = phase(t, 0.2f, 0.9f)
        bounce = 1f
    }

    /** 待命：静止的、分开的灰色链环 */
    fun showIdle() {
        animator?.cancel()
        growA = 1f; growB = 1f; lock = 0f; apart = 1f; gray = 1f; bounce = 1f
        invalidate()
    }

    private fun animate(ms: Long, interpolator: android.animation.TimeInterpolator, frame: (Float) -> Unit) {
        animator?.cancel()
        frame(0f)
        invalidate()
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = ms
            this.interpolator = interpolator
            addUpdateListener { frame(it.animatedValue as Float); invalidate() }
            start()
        }
    }

    private fun phase(t: Float, start: Float, end: Float) = ((t - start) / (end - start)).coerceIn(0f, 1f)

    override fun onDetachedFromWindow() {
        animator?.cancel()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val side = minOf(width, height).toFloat()
        // 链环旋转后约占 1024 画布的 74%；分开时整体更长，略微缩小以免出界
        val scale = side / 760f * bounce * (1f - 0.14f * apart)
        canvas.save()
        canvas.translate(width / 2f, height / 2f)
        canvas.scale(scale, scale)
        canvas.rotate(-45f)
        canvas.translate(-512f, -512f)

        val shift = separation * apart
        val layer = canvas.saveLayer(-300f, -300f, 1324f, 1324f, null)
        // 青环一层：上方交叉点被蓝环压住
        val b = canvas.saveLayer(-300f, -300f, 1324f, 1324f, null)
        canvas.save()
        canvas.translate(shift, 0f)
        drawRing(canvas, pathB, lenB, growB, cyan, grayB)
        canvas.restore()
        cutAt(canvas, pathA, crossTop, -shift)
        canvas.restoreToCount(b)
        // 蓝环一层：下方交叉点被青环压住
        val a = canvas.saveLayer(-300f, -300f, 1324f, 1324f, null)
        canvas.save()
        canvas.translate(-shift, 0f)
        drawRing(canvas, pathA, lenA, growA, blue, grayA)
        canvas.restore()
        cutAt(canvas, pathB, crossBottom, shift)
        canvas.restoreToCount(a)
        canvas.restoreToCount(layer)
        canvas.restore()
    }

    /** 画一个环（可能只画出一部分）；彩色和灰色按 gray 混合 */
    private fun drawRing(canvas: Canvas, path: Path, length: Float, t: Float, color: Shader, mono: Shader) {
        if (t <= 0f) return
        val target = if (t >= 1f) path else segment.apply {
            reset()
            PathMeasure(path, true).getSegment(0f, length * t, this, true)
        }
        if (gray < 1f) {
            paint.shader = color
            paint.alpha = ((1f - gray) * 255).toInt()
            canvas.drawPath(target, paint)
        }
        if (gray > 0f) {
            paint.shader = mono
            paint.alpha = (gray * 255).toInt()
            canvas.drawPath(target, paint)
        }
        paint.alpha = 255
    }

    /** 在交叉点附近沿另一个环挖出细缝，宽度随 lock 张开；另一个环此刻平移了 otherShift */
    private fun cutAt(canvas: Canvas, other: Path, crossing: Path, otherShift: Float) {
        if (lock <= 0f) return
        canvas.save()
        canvas.clipPath(crossing)
        canvas.translate(otherShift, 0f)
        clear.strokeWidth = stroke + gap * 2 * lock
        canvas.drawPath(other, clear)
        canvas.restore()
    }

    private fun capsule(cx: Float, cy: Float): Path {
        val r = capsuleH / 2
        return Path().apply {
            addRoundRect(RectF(cx - capsuleW / 2, cy - r, cx + capsuleW / 2, cy + r), r, r, Path.Direction.CW)
        }
    }
}
