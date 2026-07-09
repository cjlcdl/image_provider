package com.wao27cv.courage_storage

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val sharedFileChannel = "com.wao27cv.courage_storage/shared_files"
    private var pendingSharedFiles: MutableList<String>? = null
    private var flutterEngine: FlutterEngine? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        this.flutterEngine = flutterEngine

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            sharedFileChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSharedFiles" -> {
                    val files = pendingSharedFiles?.toList() ?: emptyList<String>()
                    pendingSharedFiles = null
                    result.success(files)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return
        }

        val filePaths = mutableListOf<String>()

        when (action) {
            Intent.ACTION_SEND -> {
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (uri != null) {
                    val path = copySharedFileToCache(uri)
                    if (path != null) filePaths.add(path)
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                if (uris != null) {
                    for (uri in uris) {
                        val path = copySharedFileToCache(uri)
                        if (path != null) filePaths.add(path)
                    }
                }
            }
        }

        if (filePaths.isNotEmpty()) {
            pendingSharedFiles = filePaths
            notifyFlutter()
        }
    }

    private fun copySharedFileToCache(uri: Uri): String? {
        try {
            val fileName = getFileName(uri) ?: "shared_file_${System.currentTimeMillis()}"
            val uploadCacheDir = File(cacheDir, "shared_uploads")
            if (!uploadCacheDir.exists()) uploadCacheDir.mkdirs()
            val destFile = File(uploadCacheDir, fileName)

            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(destFile).use { output ->
                    input.copyTo(output)
                }
            }

            return destFile.absolutePath
        } catch (e: Exception) {
            e.printStackTrace()
            return null
        }
    }

    private fun getFileName(uri: Uri): String? {
        var name: String? = null
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (nameIndex >= 0 && cursor.moveToFirst()) {
                name = cursor.getString(nameIndex)
            }
        }
        if (name == null) {
            name = uri.lastPathSegment
        }
        // 处理文件名冲突
        val uploadCacheDir = File(cacheDir, "shared_uploads")
        if (!uploadCacheDir.exists()) uploadCacheDir.mkdirs()
        val destFile = File(uploadCacheDir, name ?: "shared_file")
        if (destFile.exists()) {
            val dotIndex = name?.lastIndexOf('.') ?: -1
            val baseName = if (dotIndex >= 0) name!!.substring(0, dotIndex) else name!!
            val ext = if (dotIndex >= 0) name!!.substring(dotIndex) else ""
            name = "${baseName}_${System.currentTimeMillis()}${ext}"
        }
        return name
    }

    private fun notifyFlutter() {
        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
            MethodChannel(messenger, sharedFileChannel).invokeMethod(
                "onSharedFilesReceived",
                pendingSharedFiles?.toList() ?: emptyList<String>()
            )
        }
    }
}
