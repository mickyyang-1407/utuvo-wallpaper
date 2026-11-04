package com.utuvo.wallpaper.ui

import android.os.Bundle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import com.utuvo.wallpaper.R
import com.utuvo.wallpaper.platform.Jobs
import com.utuvo.wallpaper.platform.Scheduler
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {
    private val model: AppModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val initialTab = intent.getStringExtra("tab") ?: "gallery"
        setContent { AppTheme { Root(model, initialTab) } }
    }

    override fun onResume() {
        super.onResume()
        model.reload()
        Jobs.scope.launch { Scheduler.sync(applicationContext) }
        model.runDailyIfNeeded()
    }
}

@Composable
fun Root(model: AppModel, initialTab: String) {
    var tab by rememberSaveable { mutableStateOf(initialTab) }
    var detail by rememberSaveable { mutableStateOf<String?>(null) }
    val finished by Jobs.finished.collectAsState()
    LaunchedEffect(finished) { if (finished != null) model.consumeFinished() }

    Box(Modifier.fillMaxSize().canvasBackground()) {
        val start = detail
        if (start != null) {
            BackHandler { detail = null }
            DetailScreen(model, start) { detail = null }
        } else {
            Scaffold(
                containerColor = Color.Transparent,
                bottomBar = {
                    NavigationBar(containerColor = Palette.canvas.copy(alpha = 0.92f)) {
                        val colors = NavigationBarItemDefaults.colors(selectedIconColor = Palette.accent, selectedTextColor = Palette.accent,
                            indicatorColor = Palette.accent.copy(alpha = 0.18f))
                        NavigationBarItem(tab == "gallery", { tab = "gallery" }, { Icon(Icons.Filled.Home, null) },
                            label = { Text(stringResource(R.string.tab_gallery)) }, colors = colors, modifier = Modifier.testTag("tab-gallery"))
                        NavigationBarItem(tab == "dynamic", { tab = "dynamic" }, { Icon(Icons.Filled.DateRange, null) },
                            label = { Text(stringResource(R.string.tab_dynamic)) }, colors = colors, modifier = Modifier.testTag("tab-dynamic"))
                        NavigationBarItem(tab == "settings", { tab = "settings" }, { Icon(Icons.Filled.Settings, null) },
                            label = { Text(stringResource(R.string.tab_settings)) }, colors = colors, modifier = Modifier.testTag("tab-settings"))
                    }
                },
            ) { pad ->
                Box(Modifier.padding(pad)) {
                    when (tab) {
                        "dynamic" -> DynamicScreen(model)
                        "settings" -> SettingsScreen(model)
                        else -> GalleryScreen(model) { id, ids -> model.detailIDs = ids; detail = id }
                    }
                }
            }
        }
        model.message?.let { msg ->
            AlertDialog(onDismissRequest = { model.message = null }, text = { Text(msg) },
                confirmButton = { TextButton({ model.message = null }) { Text(stringResource(R.string.ok)) } })
        }
    }
}
