package com.utuvo.wallpaper

import android.app.Application
import com.utuvo.wallpaper.platform.Jobs
import com.utuvo.wallpaper.platform.Scheduler
import kotlinx.coroutines.launch

/** 每次行程啟動（含被殺掉後重開）都把排程補回來。 */
class WallpaperApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Jobs.scope.launch {
            Scheduler.sync(this@WallpaperApp)
            // 等 WorkManager 自己整理完排程，再檢查有沒有卡住的產生工作。
            kotlinx.coroutines.delay(10_000)
            com.utuvo.wallpaper.platform.GenerateWorker.kick(this@WallpaperApp)
        }
    }
}
