package com.utuvo.wallpaper

import android.app.Application
import com.utuvo.wallpaper.platform.Jobs
import com.utuvo.wallpaper.platform.Scheduler
import kotlinx.coroutines.launch

/** 每次行程啟動（含被殺掉後重開）都把排程補回來。 */
class WallpaperApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Jobs.scope.launch { Scheduler.sync(this@WallpaperApp) }
    }
}
