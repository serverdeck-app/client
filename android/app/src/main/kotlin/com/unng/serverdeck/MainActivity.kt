package com.unng.serverdeck

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity: FlutterActivity() {
    private var bridge: AndroidBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = AndroidBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridge?.cleanup(); bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
    override fun onResume() { super.onResume(); bridge?.resumed = true }
    override fun onPause() { bridge?.resumed = false; super.onPause() }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (bridge?.activityResult(requestCode, resultCode, data) != true) super.onActivityResult(requestCode, resultCode, data)
    }
}
