package io.github.normalllll.booruflow.automation

import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.graphics.Rect
import android.os.Build
import android.os.Process
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.github.normalllll.booruflow.MainActivity
import java.io.File
import java.util.UUID

/** Copied only into the isolated Debug staging project by build_android_mcp.ps1. */
class AutomationActivity : MainActivity() {
    private var visible = false
    private var resumed = false
    private val instanceToken = UUID.randomUUID().toString()
    private var initialOrientation: Int? = null
    override fun onStart() { super.onStart(); visible = true }
    override fun onStop() { visible = false; super.onStop() }
    override fun onResume() { super.onResume(); resumed = true }
    override fun onPause() { resumed = false; super.onPause() }
    private fun flutterView(view: View): FlutterView? {
        if (view is FlutterView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) {
            val found = flutterView(view.getChildAt(index))
            if (found != null) return found
        }
        return null
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        check(applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
        check(packageName == "io.github.normalllll.booruflow.automation")
        File(filesDir, "capture-instance").writeText(instanceToken)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "booruflow/automation")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "identity" -> result.success(mapOf("package" to packageName, "pid" to Process.myPid(),
                        "instanceToken" to instanceToken, "filesPath" to filesDir.absolutePath))
                    "status" -> {
                        val view = flutterView(window.decorView)
                        if (view == null || view.width == 0) result.success(null) else {
                            val origin = IntArray(2)
                            view.getLocationOnScreen(origin)
                            val frame = Rect()
                            window.decorView.getWindowVisibleDisplayFrame(frame)
                            val keyboard = if (Build.VERSION.SDK_INT >= 30) {
                                view.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) == true
                            } else { window.decorView.height - frame.bottom > 150 * resources.displayMetrics.density }
                            result.success(mapOf("platform" to "android", "package" to packageName,
                                "pid" to Process.myPid(), "instanceToken" to instanceToken,
                                "visible" to visible, "isForeground" to resumed, "hasNativeFocus" to hasWindowFocus(),
                                "keyboardVisible" to keyboard, "viewBounds" to mapOf("x" to origin[0], "y" to origin[1],
                                    "width" to view.width, "height" to view.height)))
                        }
                    }
                    "orientation" -> {
                        if (initialOrientation == null) initialOrientation = requestedOrientation
                        when (call.arguments as? String) {
                            "portrait" -> requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                            "landscape" -> requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                            "restore" -> { requestedOrientation = initialOrientation!!; initialOrientation = null }
                            else -> { result.error("invalid_orientation", "Use portrait, landscape or restore", null); return@setMethodCallHandler }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
