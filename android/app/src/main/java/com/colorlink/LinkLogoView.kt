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

/**
 * 首页的链环标志，用代码实时绘制（几何和 tools/make-icons.swift 一致，最后一帧就是图标本身）。
 *
 * 连上电脑时播放动画：蓝环沿轮廓长出 → 青环紧跟着长出 → 交叉处的细缝张开，两个环扣在一起 → 轻轻回弹。
 * 没连接时是静止的灰色链环。
 */
class LinkLogoView(context: Context) : View(context) {

    // 1024 画布里的几何（旋转前）
    private val capsuleW = 440f
    private val capsuleH = 240f
    private val stroke = 56f
    private val gap = 22f
    private val crossingRadius = 92f

    private val pathA = capsule(352f, 512f)
    private val pathB = capsule(672f, 512f)
    private val lenA = PathMeasure(pathA, true).length
    private val lenB = PathMeasure(pathB, true).length
    private val segment = Path()

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

    /** 0 → 1 的动画进度；1 表示完整的标志 */
    private var progress = 1f
    private var colored = false
    private var animator: ValueAnimator? = null

    /** 连上：彩色并播放生长动画 */
    fun playConnect() {
        colored = true
        animator?.cancel()
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1400
            interpolator = PathInterpolator(0.25f, 0.1f, 0.25f, 1f)
            addUpdateListener { progress = it.animatedValue as Float; invalidate() }
            start()
        }
    }

    /** 没连接：静止的灰色链环 */
    fun showIdle() {
        animator?.cancel()
        colored = false
        progress = 1f
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        // 三段：蓝环长出 0~0.55，青环长出 0.25~0.8，扣合（细缝张开）0.75~1，最后回弹
        val growA = phase(0f, 0.55f)
        val growB = phase(0.25f, 0.8f)
        val lock = phase(0.75f, 1f)
        val bounce = if (progress < 1f && lock > 0f) 1f + 0.06f * kotlin.math.sin(lock * Math.PI).toFloat() else 1f

        val side = minOf(width, height).toFloat()
        val scale = side / 760f * bounce // 链环旋转后约占 1024 画布的 74%
        canvas.save()
        canvas.translate(width / 2f, height / 2f)
        canvas.scale(scale, scale)
        canvas.rotate(-45f)
        canvas.translate(-512f, -512f)

        val layer = canvas.saveLayer(-200f, -200f, 1224f, 1224f, null)
        // 青环一层：上方交叉点被蓝环压住
        val b = canvas.saveLayer(-200f, -200f, 1224f, 1224f, null)
        drawPartial(canvas, pathB, lenB, growB, if (colored) cyan else grayB)
        cutAt(canvas, pathA, 408f, lock)
        canvas.restoreToCount(b)
        // 蓝环一层：下方交叉点被青环压住
        val a = canvas.saveLayer(-200f, -200f, 1224f, 1224f, null)
        drawPartial(canvas, pathA, lenA, growA, if (colored) blue else grayA)
        cutAt(canvas, pathB, 616f, lock)
        canvas.restoreToCount(a)
        canvas.restoreToCount(layer)
        canvas.restore()
    }

    private fun phase(start: Float, end: Float) = ((progress - start) / (end - start)).coerceIn(0f, 1f)

    private fun drawPartial(canvas: Canvas, path: Path, length: Float, t: Float, shader: Shader) {
        if (t <= 0f) return
        paint.shader = shader
        if (t >= 1f) {
            canvas.drawPath(path, paint)
            return
        }
        segment.reset()
        PathMeasure(path, true).getSegment(0f, length * t, segment, true)
        canvas.drawPath(segment, paint)
    }

    /** 在交叉点附近沿另一个环挖出细缝；t 控制缝的宽度，从 0 张开到完整 */
    private fun cutAt(canvas: Canvas, other: Path, y: Float, t: Float) {
        if (t <= 0f) return
        canvas.save()
        val circle = Path().apply { addCircle(512f, y, crossingRadius, Path.Direction.CW) }
        canvas.clipPath(circle)
        clear.strokeWidth = stroke + gap * 2 * t
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
