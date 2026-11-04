package com.utuvo.wallpaper.ui

import androidx.appcompat.app.AppCompatDelegate
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.os.LocaleListCompat
import com.utuvo.wallpaper.BuildConfig
import com.utuvo.wallpaper.R
import com.utuvo.wallpaper.core.AppPaths
import com.utuvo.wallpaper.core.DailyGenerationService
import com.utuvo.wallpaper.core.GenerationLog
import com.utuvo.wallpaper.core.RotationFrequency
import com.utuvo.wallpaper.platform.AppClock
import com.utuvo.wallpaper.platform.Scheduler

/** 設定：API key（Keystore，不回填）、每日自動生成、換圖頻率（最短 15 分）、語言、最近 7 天成功率。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SettingsScreen(model: AppModel) {
    val ctx = LocalContext.current
    val prefs = model.env.prefs
    val keys = model.env.keys
    var hasKey by remember { mutableStateOf(keys.hasKey) }
    var keyInput by remember { mutableStateOf("") }
    var keyError by remember { mutableStateOf(false) }
    var daily by remember { mutableStateOf(prefs.dailyEnabled) }
    var freq by remember { mutableStateOf(prefs.rotationFrequency.let { if (it == RotationFrequency.EVERY_RUN) RotationFrequency.FIFTEEN_MINUTES else it }) }
    var favOnly by remember { mutableStateOf(prefs.favoritesOnly) }
    val locales = AppCompatDelegate.getApplicationLocales()
    val lang = if (locales.isEmpty) "system" else locales[0]?.language ?: "system"

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).statusBarsPadding()) {
        Spacer(Modifier.height(12.dp))
        Text(stringResource(R.string.tab_settings), fontSize = 30.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(12.dp))
        GlassCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.api_key), fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Text(stringResource(if (hasKey) R.string.api_saved else R.string.not_set), color = if (hasKey) Palette.green else Palette.secondary,
                    fontSize = 13.sp, modifier = Modifier.testTag("key-status"))
            }
            Spacer(Modifier.height(8.dp))
            // 已存的 key 永不回填；輸入框永遠從空白開始。
            OutlinedTextField(keyInput, { keyInput = it; keyError = false }, Modifier.fillMaxWidth().testTag("key-field"),
                placeholder = { Text(stringResource(if (hasKey) R.string.api_replace else R.string.api_paste)) },
                visualTransformation = PasswordVisualTransformation(), singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false))
            if (keyError) Text(stringResource(R.string.api_invalid), color = Palette.orange, fontSize = 12.sp)
            Row {
                Button({
                    if (keys.save(keyInput)) { keyInput = ""; hasKey = true } else keyError = true
                }, enabled = keyInput.isNotEmpty(), colors = ButtonDefaults.buttonColors(containerColor = Palette.accent)) { Text(stringResource(R.string.save)) }
                Spacer(Modifier.width(8.dp))
                if (hasKey) TextButton({ keys.remove(); hasKey = false }) { Text(stringResource(R.string.remove), color = Palette.red) }
            }
            Text(stringResource(R.string.api_note), fontSize = 12.sp, color = Palette.secondary)
        }
        Spacer(Modifier.height(12.dp))
        GlassCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.daily_gen), fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Switch(daily, {
                    daily = it; prefs.dailyEnabled = it; Scheduler.sync(ctx); if (it) Scheduler.runDailyNow(ctx)
                }, colors = SwitchDefaults.colors(checkedTrackColor = Palette.green), modifier = Modifier.testTag("daily-switch"))
            }
            Text(stringResource(R.string.daily_note), fontSize = 12.sp, color = Palette.secondary)
            DailyGenerationService.status(model.env.paths, AppPaths.dayString(AppClock.now(ctx)))?.let { (done, total) ->
                Text(stringResource(R.string.daily_status, done, total), fontSize = 12.sp, color = Palette.secondary, modifier = Modifier.testTag("daily-status"))
            }
        }
        Spacer(Modifier.height(12.dp))
        GlassCard {
            Text(stringResource(R.string.rotation), fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(6.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for ((f, label) in listOf(RotationFrequency.FIFTEEN_MINUTES to R.string.freq_15, RotationFrequency.THIRTY_MINUTES to R.string.freq_30,
                    RotationFrequency.HOURLY to R.string.freq_hourly, RotationFrequency.DAILY to R.string.freq_daily)) {
                    FilterChip(freq == f, { freq = f; prefs.rotationFrequency = f; Scheduler.sync(ctx) }, { Text(stringResource(label)) }, colors = chipColors())
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.favorites_only), modifier = Modifier.weight(1f))
                Switch(favOnly, { favOnly = it; prefs.favoritesOnly = it }, colors = SwitchDefaults.colors(checkedTrackColor = Palette.green))
            }
            Text(stringResource(R.string.rotation_note), fontSize = 12.sp, color = Palette.secondary)
        }
        Spacer(Modifier.height(12.dp))
        GlassCard(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.language), fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(6.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for ((tag, label) in listOf("system" to R.string.lang_system, "zh" to R.string.lang_zh, "en" to R.string.lang_en)) {
                    FilterChip(lang == tag, {
                        AppCompatDelegate.setApplicationLocales(when (tag) {
                            "zh" -> LocaleListCompat.forLanguageTags("zh-TW")
                            "en" -> LocaleListCompat.forLanguageTags("en")
                            else -> LocaleListCompat.getEmptyLocaleList()
                        })
                    }, { Text(stringResource(label)) }, colors = chipColors(), modifier = Modifier.testTag("lang-$tag"))
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        GlassCard(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.success_7d), fontWeight = FontWeight.SemiBold)
            val s = remember { model.summary() }
            if (s == null) Text(stringResource(R.string.no_records), fontSize = 13.sp, color = Palette.secondary)
            else {
                Text(stringResource(R.string.success_n, s.succeeded, s.total), fontSize = 13.sp, color = Palette.secondary)
                if (s.failures.isNotEmpty()) {
                    Text(stringResource(R.string.failures, s.failures.joinToString("、") { (o, n) -> "${Strings.core(ctx, GenerationLog.labelKey(o))} $n" }),
                        fontSize = 12.sp, color = Palette.secondary)
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        GlassCard {
            Row {
                Text(stringResource(R.string.storage), modifier = Modifier.weight(1f))
                val bytes = remember { model.env.paths.usedBytes() }
                Text("%.1f MB".format(bytes / 1_048_576.0), color = Palette.secondary)
            }
            Row {
                Text(stringResource(R.string.version), modifier = Modifier.weight(1f))
                Text(BuildConfig.VERSION_NAME + if (BuildConfig.DEBUG) " (debug)" else "", color = Palette.secondary)
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}
