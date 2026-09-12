package com.tavre.qingjuan

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : AudioServiceActivity() {
    companion object {
        private const val FILE_CHANNEL = "qingjuan/files"
        private const val READER_CHANNEL = "qingjuan/reader"
        private const val CREATE_DOCUMENT_REQUEST = 0x514A
        private const val TARGET_REFRESH_RATE = 120f
        private const val REFRESH_RATE_TOLERANCE = 0.5f
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingSource: File? = null
    private var readerChannel: MethodChannel? = null
    private var volumeKeyReadingEnabled = false
    private var readerSystemUiEnabled = false
    private var readerBackgroundColor = Color.BLACK
    private var hostStatusBarColor: Int? = null
    private var hostNavigationBarColor: Int? = null
    private var hostDecorBackground: Drawable? = null
    private var hostSystemUiVisibility: Int? = null
    private var hostCutoutMode: Int? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        preferHighRefreshRate()
    }

    override fun onResume() {
        super.onResume()
        preferHighRefreshRate()
        if (readerSystemUiEnabled) {
            window.decorView.post(::applyReaderSystemUi)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && readerSystemUiEnabled) {
            window.decorView.post(::applyReaderSystemUi)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_CHANNEL)
            .setMethodCallHandler(::handleFileMethod)
        readerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            READER_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setVolumeKeyEnabled" -> {
                        volumeKeyReadingEnabled = call.arguments as? Boolean ?: false
                        result.success(null)
                    }

                    "setReaderSystemUi" -> {
                        val arguments = call.arguments as? Map<*, *>
                        val enabled = arguments?.get("enabled") as? Boolean
                            ?: call.arguments as? Boolean
                            ?: false
                        val backgroundColor =
                            (arguments?.get("backgroundColor") as? Number)?.toInt()
                                ?: Color.BLACK
                        setReaderSystemUi(enabled, backgroundColor)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (volumeKeyReadingEnabled &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            if (event?.repeatCount == 0) {
                readerChannel?.invokeMethod(
                    "volumeKey",
                    if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) "up" else "down",
                )
            }
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (volumeKeyReadingEnabled &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    private fun setReaderSystemUi(enabled: Boolean, backgroundColor: Int) {
        if (enabled) {
            if (!readerSystemUiEnabled) captureHostSystemUi()
            readerSystemUiEnabled = true
            readerBackgroundColor = backgroundColor
            applyReaderSystemUi()
            window.decorView.post {
                if (readerSystemUiEnabled) applyReaderSystemUi()
            }
            window.decorView.postDelayed({
                if (readerSystemUiEnabled) applyReaderSystemUi()
            }, 250L)
            return
        }

        readerSystemUiEnabled = false
        restoreHostSystemUi()
    }

    @Suppress("DEPRECATION")
    private fun captureHostSystemUi() {
        hostStatusBarColor = window.statusBarColor
        hostNavigationBarColor = window.navigationBarColor
        hostDecorBackground = window.decorView.background
            ?.constantState
            ?.newDrawable()
            ?.mutate()
        hostSystemUiVisibility = window.decorView.systemUiVisibility
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            hostCutoutMode = window.attributes.layoutInDisplayCutoutMode
        }
    }

    @Suppress("DEPRECATION")
    private fun applyReaderSystemUi() {
        if (!readerSystemUiEnabled) return

        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        window.clearFlags(WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS)
        window.statusBarColor = readerBackgroundColor
        window.navigationBarColor = readerBackgroundColor
        window.decorView.setBackgroundColor(readerBackgroundColor)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val attributes = window.attributes
            attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            window.attributes = attributes
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let { controller ->
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(WindowInsets.Type.statusBars())
            }
            return
        }

        val edgeToEdge = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        window.decorView.systemUiVisibility =
            edgeToEdge or View.SYSTEM_UI_FLAG_FULLSCREEN
    }

    @Suppress("DEPRECATION")
    private fun restoreHostSystemUi() {
        window.statusBarColor = hostStatusBarColor ?: Color.TRANSPARENT
        window.navigationBarColor = hostNavigationBarColor ?: Color.TRANSPARENT
        window.decorView.background = hostDecorBackground

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val attributes = window.attributes
            attributes.layoutInDisplayCutoutMode = hostCutoutMode
                ?: WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT
            window.attributes = attributes
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.show(WindowInsets.Type.statusBars())
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
            window.decorView.systemUiVisibility = hostSystemUiVisibility
                ?: (View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
        }

        hostStatusBarColor = null
        hostNavigationBarColor = null
        hostDecorBackground = null
        hostSystemUiVisibility = null
        hostCutoutMode = null
    }

    @Suppress("DEPRECATION")
    private fun preferHighRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val activeDisplay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            windowManager.defaultDisplay
        } ?: return
        val currentMode = activeDisplay.mode
        val sameResolutionModes = activeDisplay.supportedModes.filter { mode ->
            mode.physicalWidth == currentMode.physicalWidth &&
                mode.physicalHeight == currentMode.physicalHeight
        }
        val atOrBelowTarget = sameResolutionModes
            .filter { it.refreshRate <= TARGET_REFRESH_RATE + REFRESH_RATE_TOLERANCE }
            .maxByOrNull { it.refreshRate }
        val aboveTarget = sameResolutionModes
            .filter { it.refreshRate > TARGET_REFRESH_RATE + REFRESH_RATE_TOLERANCE }
            .minByOrNull { it.refreshRate }
        val preferredMode = when {
            atOrBelowTarget != null && atOrBelowTarget.refreshRate > 60.5f -> {
                atOrBelowTarget
            }

            aboveTarget != null -> aboveTarget
            else -> atOrBelowTarget
        } ?: return
        requestFlutterSurfaceFrameRate(preferredMode.refreshRate)
        if (preferredMode.modeId == currentMode.modeId) return
        val attributes = window.attributes
        if (attributes.preferredDisplayModeId == preferredMode.modeId) return
        attributes.preferredDisplayModeId = preferredMode.modeId
        window.attributes = attributes
    }

    private fun requestFlutterSurfaceFrameRate(frameRate: Float) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        window.decorView.post {
            val surface = findSurfaceView(window.decorView)?.holder?.surface
            if (surface?.isValid != true) return@post
            surface.setFrameRate(
                frameRate,
                Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
            )
        }
    }

    private fun findSurfaceView(view: View): SurfaceView? {
        if (view is SurfaceView) return view
        if (view !is ViewGroup) return null
        for (index in 0 until view.childCount) {
            findSurfaceView(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun handleFileMethod(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveFile") {
            result.notImplemented()
            return
        }
        if (pendingResult != null) {
            result.error("save_in_progress", "已有文件正在等待保存", null)
            return
        }

        val sourcePath = call.argument<String>("sourcePath")
        val suggestedName = call.argument<String>("suggestedName")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        if (sourcePath.isNullOrBlank() || suggestedName.isNullOrBlank()) {
            result.error("invalid_arguments", "保存文件参数不完整", null)
            return
        }

        val canonicalSource = try {
            File(sourcePath).canonicalFile
        } catch (error: Exception) {
            result.error("invalid_source", "无法读取导出缓存文件", error.message)
            return
        }
        val cacheRoot = cacheDir.canonicalFile
        if (!canonicalSource.isFile ||
            !canonicalSource.path.startsWith(cacheRoot.path + File.separator)
        ) {
            result.error("invalid_source", "只能保存应用缓存中的导出文件", null)
            return
        }

        pendingResult = result
        pendingSource = canonicalSource
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, suggestedName)
        }
        try {
            startActivityForResult(intent, CREATE_DOCUMENT_REQUEST)
        } catch (error: Exception) {
            pendingResult = null
            pendingSource = null
            result.error("document_picker_unavailable", "无法打开系统文档选择器", error.message)
        }
    }

    @Deprecated("Deprecated in Android; retained for Flutter 3.24 compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != CREATE_DOCUMENT_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingResult
        val source = pendingSource
        pendingResult = null
        pendingSource = null
        if (result == null || source == null) return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }

        val target = data.data!!
        try {
            contentResolver.openOutputStream(target, "w").use { output ->
                requireNotNull(output) { "无法打开系统文档目标" }
                FileInputStream(source).use { input -> input.copyTo(output) }
            }
            result.success(target.toString())
        } catch (error: Exception) {
            result.error("save_failed", "写入系统文档失败", error.message)
        }
    }
}
