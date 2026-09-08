package com.myservices.myservices_tv

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.myservices.myservices_tv/device_type"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAndroidTv" -> result.success(isRunningOnTv())
                    else -> result.notImplemented()
                }
            }
    }

    // Screen size/density can't reliably tell a TV from a phone -- real and
    // emulated Android TV devices commonly report the same logical
    // shortestSide range as many phones. This is the OS-level signal Android
    // itself uses: a static hardware-feature flag OR-ed with the live UI mode,
    // matching Google's own "Handle TV hardware" guidance.
    private fun isRunningOnTv(): Boolean {
        val hasLeanback = packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        val isTvUiMode = uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        return hasLeanback || isTvUiMode
    }
}
