package dev.bridgey.android.control

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.accessibilityservice.InputMethod
import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.widget.LinearLayout
import android.widget.TextView
import androidx.annotation.RequiresApi
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.BridgeyLogging
import dev.bridgey.android.LogCategory
import dev.bridgey.android.R
import dev.bridgey.android.display.ControlKey
import dev.bridgey.android.display.ControlNavigation

/**
 * "Bridgey control": the accessibility service a Mac's control goes through (docs/protocol.md "Mac controls the phone").
 * Off until the person turns it on in Android's accessibility settings. It performs gestures and Back, Home and Recents,
 * and from Android 13 types into the focused editor as an accessibility input method. It never reads window content
 * (canRetrieveWindowContent is off), ignores every accessibility event, never touches the clipboard and does nothing
 * unless a Mac controls the phone through PhoneControlHub. While one does, it shows the indicator with Stop. From Android
 * 11 it also takes screenshots, only for a share with a Mac allowed without asking when nobody approved Android's video
 * prompt (unattended access, ScreenShareHub); the sharing notification with Stop shows for as long as that runs.
 */
class BridgeyControlService : AccessibilityService(), ControlService, dev.bridgey.android.screen.ScreenshotTaker {
    private val main = Handler(Looper.getMainLooper())

    /** The last dispatched stroke of each finger that is still down, so the next part continues it. */
    private val strokes = HashMap<Int, GestureDescription.StrokeDescription>()
    private val strokeLock = Any()
    private var indicator: View? = null
    private var prompt: View? = null

    /** Main thread only: the bar shows control while a Mac controls the phone, else the screenshot share's viewer. */
    private var controlBar: Pair<String, () -> Unit>? = null
    private var viewingBar: Pair<String, () -> Unit>? = null

    @Volatile private var inputMethodReady = false

    private val app: BridgeyApplication? get() = application as? BridgeyApplication

    override fun onServiceConnected() {
        super.onServiceConnected()
        current = this
        BridgeyLogging.i(LogCategory.REMOTE_CONTROL, "CONTROL service connected")
        app?.phoneControlChanged()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        disconnected()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        disconnected()
        super.onDestroy()
    }

    private fun disconnected() {
        if (current !== this) return
        current = null
        synchronized(strokeLock) { strokes.clear() }
        main.post {
            controlBar = null
            viewingBar = null
            removeIndicator()
            removePrompt()
        }
        BridgeyLogging.i(LogCategory.REMOTE_CONTROL, "CONTROL service disconnected")
        app?.phoneControlChanged()
    }

    /** No events are asked for; none are read. */
    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    override fun onCreateInputMethod(): InputMethod {
        inputMethodReady = true
        return InputMethod(this)
    }

    // MARK: ControlService

    override val canType: Boolean get() = Build.VERSION.SDK_INT >= PhoneControlLimits.TYPING_SDK && inputMethodReady

    override fun dispatch(gesture: PlannedGesture, done: (Boolean) -> Unit): Boolean {
        val builder = GestureDescription.Builder()
        val next = HashMap<Int, GestureDescription.StrokeDescription>()
        val duration = gesture.durationMillis.coerceIn(1, GestureDescription.getMaxGestureDuration())
        synchronized(strokeLock) {
            for (planned in gesture.strokes) {
                val path = Path()
                val first = planned.points.firstOrNull() ?: return false
                path.moveTo(first.x.toFloat(), first.y.toFloat())
                if (planned.points.size == 1) path.lineTo(first.x.toFloat(), first.y.toFloat())
                planned.points.drop(1).forEach { path.lineTo(it.x.toFloat(), it.y.toFloat()) }
                val stroke = runCatching {
                    if (planned.continuing) {
                        val previous = strokes[planned.finger] ?: return false
                        previous.continueStroke(path, 0, duration, planned.willContinue)
                    } else {
                        GestureDescription.StrokeDescription(path, 0, duration, planned.willContinue)
                    }
                }.getOrElse {
                    BridgeyLogging.w(LogCategory.REMOTE_CONTROL, "CONTROL stroke refused", it)
                    return false
                }
                builder.addStroke(stroke)
                if (planned.willContinue) next[planned.finger] = stroke
            }
            val description = runCatching { builder.build() }.getOrElse { return false }
            val started = dispatchGesture(description, object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) = done(true)
                override fun onCancelled(gestureDescription: GestureDescription?) {
                    synchronized(strokeLock) { strokes.clear() }
                    done(false)
                }
            }, main)
            if (started) {
                strokes.clear()
                strokes.putAll(next)
            } else {
                strokes.clear()
            }
            return started
        }
    }

    // MARK: ScreenshotTaker

    override fun screenshot(executor: java.util.concurrent.Executor, done: (dev.bridgey.android.screen.ScreenShot) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            executor.execute { done(dev.bridgey.android.screen.ScreenShot.Failed(dev.bridgey.android.screen.ShotError.NO_ACCESS)) }
            return
        }
        takeDisplayScreenshot(executor, done)
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun takeDisplayScreenshot(executor: java.util.concurrent.Executor, done: (dev.bridgey.android.screen.ScreenShot) -> Unit) {
        takeScreenshot(android.view.Display.DEFAULT_DISPLAY, executor, object : TakeScreenshotCallback {
            override fun onSuccess(screenshot: ScreenshotResult) {
                val buffer = screenshot.hardwareBuffer
                val bitmap = runCatching { android.graphics.Bitmap.wrapHardwareBuffer(buffer, screenshot.colorSpace) }.getOrNull()
                if (bitmap == null) {
                    buffer.close()
                    done(dev.bridgey.android.screen.ScreenShot.Failed(dev.bridgey.android.screen.ShotError.OTHER))
                    return
                }
                done(dev.bridgey.android.screen.ScreenShot.Frame(bitmap) {
                    bitmap.recycle()
                    buffer.close()
                })
            }

            override fun onFailure(errorCode: Int) {
                done(dev.bridgey.android.screen.ScreenShot.Failed(screenshotError(errorCode)))
            }
        })
    }

    override fun navigate(action: ControlNavigation): Boolean = performGlobalAction(
        when (action) {
            ControlNavigation.BACK -> GLOBAL_ACTION_BACK
            ControlNavigation.HOME -> GLOBAL_ACTION_HOME
            ControlNavigation.RECENTS -> GLOBAL_ACTION_RECENTS
        },
    )

    override fun text(text: String): Typed {
        if (Build.VERSION.SDK_INT < PhoneControlLimits.TYPING_SDK) return Typed.FAILED
        return typeText(text)
    }

    override fun key(key: ControlKey, down: Boolean, shift: Boolean): Typed {
        if (Build.VERSION.SDK_INT < PhoneControlLimits.TYPING_SDK) return Typed.FAILED
        return typeKey(key, down, shift)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun typeText(text: String): Typed {
        val method = inputMethod ?: return Typed.FAILED
        if (!method.currentInputStarted) return Typed.NO_EDITOR
        val connection = method.currentInputConnection ?: return Typed.NO_EDITOR
        return runCatching { connection.commitText(text, 1, null); Typed.TYPED }.getOrDefault(Typed.FAILED)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun typeKey(key: ControlKey, down: Boolean, shift: Boolean): Typed {
        val code = keyCode(key) ?: return Typed.TYPED
        val method = inputMethod ?: return Typed.FAILED
        if (!method.currentInputStarted) return Typed.NO_EDITOR
        val connection = method.currentInputConnection ?: return Typed.NO_EDITOR
        val now = SystemClock.uptimeMillis()
        val meta = if (shift) KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON else 0
        val event = KeyEvent(now, now, if (down) KeyEvent.ACTION_DOWN else KeyEvent.ACTION_UP, code, 0, meta)
        return runCatching { connection.sendKeyEvent(event); Typed.TYPED }.getOrDefault(Typed.FAILED)
    }

    override fun showIndicator(macName: String, onStop: () -> Unit) {
        main.post {
            controlBar = macName to onStop
            drawIndicator()
        }
    }

    override fun hideIndicator() {
        main.post {
            controlBar = null
            drawIndicator()
        }
    }

    override fun showViewing(macName: String, onStop: () -> Unit) {
        main.post {
            viewingBar = macName to onStop
            drawIndicator()
        }
    }

    override fun hideViewing() {
        main.post {
            viewingBar = null
            drawIndicator()
        }
    }

    /** Control's bar wins; with no control, a screenshot share's bar; else none. */
    private fun drawIndicator() {
        removeIndicator()
        val (text, stopDescription, onStop) = controlBar?.let { (name, stop) ->
            Triple(getString(R.string.control_indicator_text, name), getString(R.string.control_stop_description, name), stop)
        } ?: viewingBar?.let { (name, stop) ->
            Triple(getString(R.string.screen_indicator_viewing, name), getString(R.string.screen_indicator_stop_description, name), stop)
        } ?: return
        runCatching { addIndicator(text, stopDescription, onStop) }.onFailure { BridgeyLogging.w(LogCategory.REMOTE_CONTROL, "CONTROL indicator", it) }
    }

    override fun showPrompt(macName: String, answer: (Boolean) -> Unit) {
        main.post {
            removePrompt()
            runCatching { addPrompt(macName, answer) }.onFailure { BridgeyLogging.w(LogCategory.REMOTE_CONTROL, "CONTROL prompt", it) }
        }
    }

    override fun hidePrompt() {
        main.post { removePrompt() }
    }

    // MARK: The indicator

    /**
     * "MacBook Air is controlling this phone" (or "is viewing this phone" for a screenshot share) with Stop, over the top
     * of the screen. An accessibility overlay needs no other permission, and it shows in the Mac's picture too. Only the
     * bar takes touches; the rest of the screen does not.
     */
    @SuppressLint("SetTextI18n")
    private fun addIndicator(message: String, stopDescription: String, onStop: () -> Unit) {
        val manager = getSystemService(WindowManager::class.java) ?: return
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        val dark = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val surface = if (dark) 0xF2151C29.toInt() else 0xF2FFFFFF.toInt()
        val onSurface = if (dark) 0xFFF4F7FA.toInt() else 0xFF050B18.toInt()
        val outline = if (dark) 0xFF2A303F.toInt() else 0xFFDDE3EB.toInt()
        val good = if (dark) 0xFF5EF2B2.toInt() else 0xFF006C49.toInt()
        val danger = if (dark) 0xFFFFB4A8.toInt() else 0xFFB3261E.toInt()
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(6), dp(6), dp(6))
            background = GradientDrawable().apply {
                cornerRadius = dp(22).toFloat()
                setColor(surface)
                setStroke(dp(1), outline)
            }
            elevation = dp(6).toFloat()
        }
        val dot = View(this).apply {
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(good) }
        }
        bar.addView(dot, LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginEnd = dp(10) })
        val label = TextView(this).apply {
            text = message
            setTextColor(onSurface)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        // The name takes what is left; Stop always keeps its full width.
        bar.addView(label, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = dp(10) })
        val stop = TextView(this).apply {
            text = getString(R.string.control_stop)
            setTextColor(danger)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            isSingleLine = true
            setPadding(dp(14), dp(6), dp(14), dp(6))
            minHeight = dp(32)
            background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(danger and 0x00FFFFFF or 0x26000000)
            }
            isClickable = true
            isFocusable = true
            contentDescription = stopDescription
            setOnClickListener { onStop() }
        }
        bar.addView(stop, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        val statusBar = resources.getIdentifier("status_bar_height", "dimen", "android").takeIf { it != 0 }
            ?.let(resources::getDimensionPixelSize) ?: dp(24)
        val width = minOf(resources.displayMetrics.widthPixels - dp(32), dp(420))
        val params = WindowManager.LayoutParams(
            width,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = statusBar + dp(8)
            title = "Bridgey control"
        }
        manager.addView(bar, params)
        indicator = bar
    }

    private fun removeIndicator() {
        val view = indicator ?: return
        indicator = null
        runCatching { getSystemService(WindowManager::class.java)?.removeView(view) }
    }

    /**
     * Ask each time, on the screen: "MacBook Air wants to control this phone" with Don't allow and Allow. Android may
     * redact notifications while the screen is shared, so the question is asked here too. Nothing is injected while it
     * shows, so the Mac cannot answer it.
     */
    private fun addPrompt(macName: String, answer: (Boolean) -> Unit) {
        val manager = getSystemService(WindowManager::class.java) ?: return
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        val dark = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val surface = if (dark) 0xF7151C29.toInt() else 0xF7FFFFFF.toInt()
        val onSurface = if (dark) 0xFFF4F7FA.toInt() else 0xFF050B18.toInt()
        val variant = if (dark) 0xFF9AA8B8.toInt() else 0xFF4C5262.toInt()
        val outline = if (dark) 0xFF2A303F.toInt() else 0xFFDDE3EB.toInt()
        val primary = if (dark) 0xFF54C7F5.toInt() else 0xFF006685.toInt()
        val onPrimary = if (dark) 0xFF050B18.toInt() else 0xFFFFFFFF.toInt()
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(16), dp(18), dp(12))
            background = GradientDrawable().apply {
                cornerRadius = dp(24).toFloat()
                setColor(surface)
                setStroke(dp(1), outline)
            }
            elevation = dp(8).toFloat()
        }
        card.addView(TextView(this).apply {
            text = getString(R.string.control_ask_title, macName)
            setTextColor(onSurface)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            typeface = android.graphics.Typeface.DEFAULT_BOLD
        })
        card.addView(TextView(this).apply {
            text = getString(R.string.control_ask_text)
            setTextColor(variant)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setPadding(0, dp(4), 0, dp(12))
        })
        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
        }
        fun button(label: Int, filled: Boolean, allowed: Boolean) = TextView(this).apply {
            text = getString(label)
            setTextColor(if (filled) onPrimary else primary)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            isSingleLine = true
            minHeight = dp(40)
            setPadding(dp(18), dp(8), dp(18), dp(8))
            background = GradientDrawable().apply {
                cornerRadius = dp(20).toFloat()
                setColor(if (filled) primary else 0x00000000)
            }
            isClickable = true
            isFocusable = true
            setOnClickListener {
                removePrompt()
                answer(allowed)
            }
        }
        buttons.addView(button(R.string.control_ask_deny, filled = false, allowed = false))
        buttons.addView(button(R.string.control_ask_allow, filled = true, allowed = true), LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { marginStart = dp(8) })
        card.addView(buttons)
        val statusBar = resources.getIdentifier("status_bar_height", "dimen", "android").takeIf { it != 0 }
            ?.let(resources::getDimensionPixelSize) ?: dp(24)
        val params = WindowManager.LayoutParams(
            minOf(resources.displayMetrics.widthPixels - dp(32), dp(420)),
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = statusBar + dp(8)
            title = "Bridgey control request"
        }
        manager.addView(card, params)
        prompt = card
    }

    private fun removePrompt() {
        val view = prompt ?: return
        prompt = null
        runCatching { getSystemService(WindowManager::class.java)?.removeView(view) }
    }

    companion object {
        @Volatile var current: BridgeyControlService? = null
            private set

        fun component(context: Context) = ComponentName(context, BridgeyControlService::class.java)

        /** The service is on in Android's accessibility settings (it may not be connected yet). */
        fun enabled(context: Context): Boolean {
            val list = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
            val wanted = component(context)
            return list.split(':').any { ComponentName.unflattenFromString(it) == wanted }
        }

        /** Android's accessibility settings, where the person turns Bridgey control on or off. */
        fun settingsIntent(): Intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        /** AccessibilityService's screenshot error codes, as the share's pacer reads them. */
        fun screenshotError(code: Int): dev.bridgey.android.screen.ShotError = when (code) {
            AccessibilityService.ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT -> dev.bridgey.android.screen.ShotError.TOO_SOON
            AccessibilityService.ERROR_TAKE_SCREENSHOT_NO_ACCESSIBILITY_ACCESS -> dev.bridgey.android.screen.ShotError.NO_ACCESS
            AccessibilityService.ERROR_TAKE_SCREENSHOT_INVALID_DISPLAY -> dev.bridgey.android.screen.ShotError.INVALID_DISPLAY
            else -> dev.bridgey.android.screen.ShotError.OTHER
        }

        fun keyCode(key: ControlKey): Int? = when (key) {
            ControlKey.ENTER -> KeyEvent.KEYCODE_ENTER
            ControlKey.TAB -> KeyEvent.KEYCODE_TAB
            ControlKey.BACKSPACE -> KeyEvent.KEYCODE_DEL
            ControlKey.ESCAPE -> KeyEvent.KEYCODE_ESCAPE
            ControlKey.LEFT -> KeyEvent.KEYCODE_DPAD_LEFT
            ControlKey.RIGHT -> KeyEvent.KEYCODE_DPAD_RIGHT
            ControlKey.UP -> KeyEvent.KEYCODE_DPAD_UP
            ControlKey.DOWN -> KeyEvent.KEYCODE_DPAD_DOWN
            ControlKey.HOME -> KeyEvent.KEYCODE_MOVE_HOME
            ControlKey.END -> KeyEvent.KEYCODE_MOVE_END
            ControlKey.PAGE_UP -> KeyEvent.KEYCODE_PAGE_UP
            ControlKey.PAGE_DOWN -> KeyEvent.KEYCODE_PAGE_DOWN
            ControlKey.DELETE -> KeyEvent.KEYCODE_FORWARD_DEL
            ControlKey.SHIFT, ControlKey.CONTROL, ControlKey.ALT, ControlKey.META -> null
        }
    }
}
