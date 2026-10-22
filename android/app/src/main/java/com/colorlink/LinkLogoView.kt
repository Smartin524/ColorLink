package com.colorlink

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PathMeasure
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.Shader
import android.os.Build
import android.view.View
import android.view.animation.LinearInterpolator
import android.view.animation.PathInterpolator
import kotlin.math.max
import kotlin.math.sin

/**
 * 首页的链环标志，用代码实时绘制（几何和 tools/make-icons.swift 一致，扣合状态就是图标本身）。
 *
 * - 连上：两个灰环摆回一条斜线并拢，颜色沿轮廓长满（蓝环先、青环紧跟）→ 交叉处细缝张开、扣在一起 → 轻轻回弹
 * - 断开：细缝合上（解扣）→ 两个环各自转开，摆成「八」字（左环朝右上、右环朝左上），颜色沿轮廓退回成灰色
 * - 两种动画都从当前画面出发：播到一半状态变了，就从那一帧接着往回走，不会跳回开头重播
 *
 * 只在动画播放的一秒多里逐帧重绘，静止时不耗电。
 */
class LinkLogoView(context: Context) : View(context) {

    // 1024 画布里的几何（旋转前）：两个胶囊沿 x 轴排开，交叉点在 x = 512
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
    private val crossTop = Path().apply { addCircle(512f, 408f, crossingRadius, Path.Direction.CW) }
    private val crossBottom = Path().apply { addCircle(512f, 616f, crossingRadius, Path.Direction.CW) }

    /**
     * 每个环的姿态（相对标志中心，1024 单位）：扣合时整条链斜 45°；断开时摆成「八」字。
     * 左环 -45° → -60°（更竖，朝右上）；右环 -45° → -120°（朝左上），两环都逆时针转，像松开的样子。
     */
    private class Pose(val x: Float, val y: Float, val angle: Float)
    private val linkedA = Pose(-113.1f, 113.1f, -45f)
    private val linkedB = Pose(113.1f, -113.1f, -45f)
    private val apartA = Pose(-220f, 0f, -60f)
    private val apartB = Pose(220f, 0f, -120f)

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
    private var colorA = 0f // 蓝环沿轮廓上色的比例：0 全灰，1 全彩
    private var colorB = 0f
    private var lock = 0f // 交叉处细缝张开的程度：0 未扣合，1 扣合
    private var apart = 1f // 0 扣合的斜线姿态，1 「八」字姿态
    private var bounce = 1f

    private var animator: ValueAnimator? = null
    private val ease = PathInterpolator(0.33f, 0f, 0.2f, 1f)
    private val poseA = Matrix()
    private val poseB = Matrix()
    private val relative = Matrix()
    private val layerBounds = RectF(-560f, -560f, 560f, 560f)

    /** 连上：并拢、上色，然后扣合。从当前画面出发，已经走完的部分不再重复 */
    fun playConnect() {
        val a0 = apart; val cA0 = colorA; val cB0 = colorB; val l0 = lock; val b0 = bounce
        // 第一段（并拢 + 上色）还剩多少，就花多少时间；扣合段同理
        val gather = 980f * max(a0, max(1f - cA0, 1f - cB0))
        val latch = 420f * (1f - l0)
        val latchStart = max(0f, gather - 80f)
        run(latchStart + latch) { ms ->
            apart = lerp(a0, 0f, window(ms, 0f, gather))
            colorA = lerp(cA0, 1f, window(ms, 0f, gather * 0.85f))
            colorB = lerp(cB0, 1f, window(ms, gather * 0.3f, gather))
            val p = window(ms, latchStart, latchStart + latch, linear = true)
            lock = lerp(l0, 1f, ease.getInterpolation(p))
            bounce = if (latch > 0f) 1f + 0.06f * sin(p * Math.PI).toFloat() else lerp(b0, 1f, window(ms, 0f, 200f))
        }
    }

    /** 断开：先解扣，再转开成「八」字，颜色沿轮廓退回成灰色。同样从当前画面出发 */
    fun playDisconnect() {
        val a0 = apart; val cA0 = colorA; val cB0 = colorB; val l0 = lock; val b0 = bounce
        val unlatch = 260f * l0
        val spread = 820f * max(1f - a0, max(cA0, cB0))
        val spreadStart = unlatch * 0.7f
        run(spreadStart + spread) { ms ->
            lock = lerp(l0, 0f, window(ms, 0f, unlatch))
            bounce = lerp(b0, 1f, window(ms, 0f, max(unlatch, 120f)))
            apart = lerp(a0, 1f, window(ms, spreadStart, spreadStart + spread))
            colorB = lerp(cB0, 0f, window(ms, spreadStart, spreadStart + spread * 0.8f))
            colorA = lerp(cA0, 0f, window(ms, spreadStart + spread * 0.15f, spreadStart + spread))
        }
    }

    /** 已连接（不播放动画）：静止的彩色扣合链环 */
    fun showConnected() {
        animator?.cancel()
        colorA = 1f; colorB = 1f; lock = 1f; apart = 0f; bounce = 1f
        invalidate()
    }

    /** 待命：静止的「八」字灰色链环 */
    fun showIdle() {
        animator?.cancel()
        colorA = 0f; colorB = 0f; lock = 0f; apart = 1f; bounce = 1f
        invalidate()
    }

    /** 按毫秒时间轴驱动 frame；每个参数在自己的时间窗里缓动，所以中途接上新动画也不会跳 */
    private fun run(totalMs: Float, frame: (Float) -> Unit) {
        animator?.cancel()
        if (totalMs <= 0f) { frame(0f); invalidate(); return }
        animator = ValueAnimator.ofFloat(0f, totalMs).apply {
            duration = totalMs.toLong()
            interpolator = LinearInterpolator()
            addUpdateListener { frame(it.animatedValue as Float); invalidate() }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationStart(a: android.animation.Animator) = highFrameRate(true)
                override fun onAnimationEnd(a: android.animation.Animator) = highFrameRate(false)
            })
            start()
        }
    }

    /** 动画期间请求高刷（Android 15+），结束后交还系统 */
    private fun highFrameRate(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 35) {
            requestedFrameRate = if (on) REQUESTED_FRAME_RATE_CATEGORY_HIGH else REQUESTED_FRAME_RATE_CATEGORY_DEFAULT
        }
    }

    /** ms 落在 [start, end] 里的缓动进度；窗口长度为 0 时直接视为已完成 */
    private fun window(ms: Float, start: Float, end: Float, linear: Boolean = false): Float {
        if (end <= start) return 1f
        val t = ((ms - start) / (end - start)).coerceIn(0f, 1f)
        return if (linear) t else ease.getInterpolation(t)
    }

    private fun lerp(a: Float, b: Float, t: Float) = a + (b - a) * t

    override fun onDetachedFromWindow() {
        animator?.cancel()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val side = minOf(width, height).toFloat()
        // 扣合时链环约占 760 单位；「八」字更宽一些（约 840），略微缩小以免出界
        val scale = side / 760f * bounce * (1f - 0.1f * apart)
        canvas.save()
        canvas.translate(width / 2f, height / 2f)
        canvas.scale(scale, scale)

        pose(poseA, 352f, linkedA, apartA)
        pose(poseB, 672f, linkedB, apartB)
        // 青环一层：上方交叉点被蓝环压住
        drawLayer(canvas, pathB, lenB, colorB, cyan, grayB, poseB, poseA, pathA, crossTop)
        // 蓝环一层：下方交叉点被青环压住
        drawLayer(canvas, pathA, lenA, colorA, blue, grayA, poseA, poseB, pathB, crossBottom)
        canvas.restore()
    }

    /** 把 1024 画布里以 (cx, 512) 为中心的环，摆到扣合 / 「八」字之间的姿态 */
    private fun pose(m: Matrix, cx: Float, linked: Pose, spread: Pose) {
        val t = apart
        m.reset()
        m.postTranslate(-cx, -512f)
        m.postRotate(lerp(linked.angle, spread.angle, t))
        m.postTranslate(lerp(linked.x, spread.x, t), lerp(linked.y, spread.y, t))
    }

    private fun drawLayer(
        canvas: Canvas, path: Path, length: Float, color: Float, colored: Shader, mono: Shader,
        own: Matrix, other: Matrix, otherPath: Path, crossing: Path,
    ) {
        val layer = canvas.saveLayer(layerBounds, null)
        canvas.concat(own)
        // 先画整圈灰色，再沿轮廓叠上彩色的部分
        paint.shader = mono
        canvas.drawPath(path, paint)
        if (color > 0f) {
            paint.shader = colored
            canvas.drawPath(if (color >= 1f) path else segment.apply {
                reset()
                PathMeasure(path, true).getSegment(0f, length * color, this, true)
            }, paint)
        }
        // 在交叉点附近沿另一个环挖出细缝，宽度随 lock 张开；交叉点跟着自己走，另一个环按相对姿态画
        if (lock > 0f) {
            canvas.clipPath(crossing)
            own.invert(relative)
            relative.preConcat(other)
            canvas.concat(relative)
            clear.strokeWidth = stroke + gap * 2 * lock
            canvas.drawPath(otherPath, clear)
        }
        canvas.restoreToCount(layer)
    }

    private fun capsule(cx: Float, cy: Float): Path {
        val r = capsuleH / 2
        return Path().apply {
            addRoundRect(RectF(cx - capsuleW / 2, cy - r, cx + capsuleW / 2, cy + r), r, r, Path.Direction.CW)
        }
    }
}
