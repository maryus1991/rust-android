package com.web2app.nativeplugin

import android.Manifest
import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.webkit.CookieManager
import android.webkit.DownloadListener
import android.webkit.URLUtil
import android.webkit.WebView
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * Hands WebView downloads to the system DownloadManager.
 *
 * - runs in the background and shows system progress / completion notifications
 * - forwards the session cookies, User-Agent and Referer of the WebView
 * - supports http(s) URLs only: blob: and data: URLs cannot be fetched by
 *   DownloadManager (documented as Platform Limited)
 */
class DownloadHandler(private val activity: Activity) : DownloadListener {
    private var webView: WebView? = null

    fun attach(view: WebView) {
        webView = view
        view.setDownloadListener(this)
    }

    override fun onDownloadStart(
        url: String?,
        userAgent: String?,
        contentDisposition: String?,
        mimetype: String?,
        contentLength: Long
    ) {
        if (url.isNullOrBlank()) return
        val uri = Uri.parse(url)
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") {
            toast("This kind of download (" + (scheme ?: "unknown") + ":) is not supported")
            return
        }
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.WRITE_EXTERNAL_STORAGE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                activity, arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), REQUEST_STORAGE
            )
            toast("Allow storage access, then start the download again")
            return
        }
        try {
            val fileName = sanitize(URLUtil.guessFileName(url, contentDisposition, mimetype))
            val request = DownloadManager.Request(uri).apply {
                if (!mimetype.isNullOrBlank()) setMimeType(mimetype)
                if (!userAgent.isNullOrBlank()) addRequestHeader("User-Agent", userAgent)
                CookieManager.getInstance().getCookie(url)?.let { addRequestHeader("Cookie", it) }
                webView?.url?.let { addRequestHeader("Referer", it) }
                setTitle(fileName)
                setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, fileName)
            }
            val manager = activity.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            manager.enqueue(request)
            toast("Downloading $fileName")
        } catch (e: Exception) {
            toast("Download failed: " + (e.message ?: "unknown error"))
        }
    }

    private fun sanitize(name: String): String {
        val cleaned = name.replace(Regex("[/\\\\:*?\"<>|\\u0000-\\u001f]"), "_").trim().trimStart('.')
        return if (cleaned.isEmpty()) "download" else cleaned
    }

    private fun toast(message: String) {
        activity.runOnUiThread { Toast.makeText(activity, message, Toast.LENGTH_LONG).show() }
    }

    private companion object {
        const val REQUEST_STORAGE = 7301
    }
}
