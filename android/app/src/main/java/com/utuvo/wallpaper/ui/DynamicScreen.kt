package com.utuvo.wallpaper.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.utuvo.wallpaper.R
import com.utuvo.wallpaper.core.DayPhase
import com.utuvo.wallpaper.core.DynamicAutoFrequency
import com.utuvo.wallpaper.core.DynamicTiming
import com.utuvo.wallpaper.core.OverviewFacts
import com.utuvo.wallpaper.platform.AppClock
import com.utuvo.wallpaper.platform.AutoStateFile
import com.utuvo.wallpaper.platform.Jobs
import com.utuvo.wallpaper.platform.Providers
import com.utuvo.wallpaper.platform.Scheduler
import com.utuvo.wallpaper.platform.Wallpapers
import kotlinx.coroutines.launch

/** 日夜：四時段預覽、場景來源（自己描述／AI 每天／每週）、切換方式、套用日夜桌布。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DynamicScreen(model: AppModel) {
    val ctx = LocalContext.current
    val prefs = model.env.prefs
    var timing by remember { mutableStateOf(prefs.dynamicTiming) }
    var auto by remember { mutableStateOf(prefs.dynamicAutoFrequency) }
    var scene by remember { mutableStateOf("") }
    var sceneID by remember { mutableStateOf(prefs.dynamicSceneID) }
    var note by remember { mutableStateOf<String?>(null) }
    val running by Jobs.running.collectAsState()
    val now = AppClock.now(ctx)
    val schedule = prefs.schedule(model.env.data, now)
    val phase = schedule.phase(now)

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).statusBarsPadding()) {
        Spacer(Modifier.height(12.dp))
        Text(stringResource(R.string.tab_dynamic), fontSize = 30.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(12.dp))
        GlassCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.dyn_enable), fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Switch(model.dynamicEnabled, { model.toggleDynamic(it) }, colors = SwitchDefaults.colors(checkedTrackColor = Palette.green),
                    modifier = Modifier.testTag("dynamic-switch"))
            }
            val next = OverviewFacts.nextPhase(schedule, now)
            if (timing != DynamicTiming.APPEARANCE) {
                Text(stringResource(R.string.now_phase, Strings.phase(ctx, phase.raw), next.second, Strings.phase(ctx, next.first.raw)),
                    color = Palette.secondary, fontSize = 13.sp, modifier = Modifier.testTag("now-phase"))
            }
            Spacer(Modifier.height(12.dp))
            Text(stringResource(R.string.four_phases), fontSize = 13.sp, color = Palette.secondary)
            Spacer(Modifier.height(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (p in listOf(DayPhase.DAWN, DayPhase.DAY, DayPhase.DUSK, DayPhase.NIGHT)) {
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        val file = remember(sceneID, p) { Wallpapers.phaseFile(ctx, sceneID, p) }
                        Box(Modifier.fillMaxWidth().aspectRatio(9f / 19.5f).clip(RoundedCornerShape(10.dp))) {
                            WallpaperImage(ctx, null, 360, Modifier.fillMaxSize(), file = file)
                        }
                        Text(Strings.phase(ctx, p.raw) + (schedule.startTime(p, now.toLocalDate(), now.zone)?.let { " $it" } ?: ""),
                            fontSize = 11.sp, color = if (p == phase) Palette.accent else Palette.secondary)
                    }
                }
            }
            Spacer(Modifier.height(6.dp))
            Text(stringResource(R.string.scene_label, if (sceneID == "demo") stringResource(R.string.demo_scene) else sceneID),
                fontSize = 12.sp, color = Palette.secondary)
            Spacer(Modifier.height(12.dp))
            Button({ model.applyDynamic() }, Modifier.fillMaxWidth().testTag("apply-dynamic"),
                colors = ButtonDefaults.buttonColors(containerColor = Palette.accent)) { Text(stringResource(R.string.apply_dynamic)) }
            Spacer(Modifier.height(6.dp))
            Text(stringResource(R.string.dynamic_auto_note), fontSize = 12.sp, color = Palette.secondary)
        }
        Spacer(Modifier.height(12.dp))
        GlassCard {
            Text(stringResource(R.string.scene_source), fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for ((f, label) in listOf(DynamicAutoFrequency.OFF to R.string.own_describe, DynamicAutoFrequency.DAILY to R.string.ai_daily,
                    DynamicAutoFrequency.WEEKLY to R.string.ai_weekly)) {
                    FilterChip(auto == f, {
                        auto = f; prefs.dynamicAutoFrequency = f; Scheduler.sync(ctx)
                    }, { Text(stringResource(label)) }, colors = chipColors(), modifier = Modifier.testTag("auto-${f.raw}"))
                }
            }
            Spacer(Modifier.height(8.dp))
            val r = running
            if (r != null && r.kind == "scene") {
                Text(stringResource(R.string.scene_progress, r.done))
                LinearProgressIndicator({ r.done / 4f }, Modifier.fillMaxWidth(), color = Palette.accent)
            } else if (auto == DynamicAutoFrequency.OFF) {
                OutlinedTextField(scene, { scene = it }, Modifier.fillMaxWidth(), placeholder = { Text(stringResource(R.string.scene_example)) })
                Spacer(Modifier.height(8.dp))
                Button({
                    note = when {
                        !Providers.canGenerate(ctx) -> ctx.getString(R.string.err_missing_key)
                        !Jobs.launchScene(ctx, scene) -> ctx.getString(R.string.busy)
                        else -> null
                    }
                }, Modifier.fillMaxWidth(), enabled = scene.isNotBlank(), colors = ButtonDefaults.buttonColors(containerColor = Palette.accent)) {
                    Text(stringResource(R.string.make_scene))
                }
                Text(stringResource(R.string.scene_note), fontSize = 12.sp, color = Palette.secondary)
            } else {
                Text(stringResource(if (auto == DynamicAutoFrequency.DAILY) R.string.ai_daily_note else R.string.ai_weekly_note),
                    fontSize = 13.sp, color = Palette.secondary)
                AutoStateFile.read(model.env.paths)?.let { s ->
                    Text(stringResource(if (s.completed) R.string.last_scene else R.string.in_progress, s.prompt), fontSize = 12.sp, color = Palette.secondary)
                }
                Spacer(Modifier.height(8.dp))
                OutlinedButton({
                    note = if (!Providers.canGenerate(ctx)) ctx.getString(R.string.err_missing_key) else null
                    if (note == null) Jobs.scope.launchAuto(ctx)
                }, Modifier.fillMaxWidth()) { Text(stringResource(R.string.ai_now)) }
                Text(stringResource(R.string.ai_cost), fontSize = 12.sp, color = Palette.secondary)
            }
            note?.let { Text(it, color = Palette.orange, fontSize = 13.sp) }
        }
        Spacer(Modifier.height(12.dp))
        GlassCard {
            Text(stringResource(R.string.timing), fontWeight = FontWeight.SemiBold)
            for ((t, label) in listOf(DynamicTiming.FIXED to R.string.timing_fixed, DynamicTiming.SOLAR to R.string.timing_solar,
                DynamicTiming.APPEARANCE to R.string.timing_appearance)) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                    androidx.compose.material3.RadioButton(timing == t, {
                        timing = t; prefs.dynamicTiming = t; Scheduler.sync(ctx)
                    })
                    Text(stringResource(label), fontSize = 14.sp)
                }
            }
            if (timing != DynamicTiming.APPEARANCE) {
                val d = now.toLocalDate()
                Text(stringResource(R.string.today_times, schedule.startTime(DayPhase.DAWN, d, now.zone) ?: "", schedule.startTime(DayPhase.DAY, d, now.zone) ?: "",
                    schedule.startTime(DayPhase.DUSK, d, now.zone) ?: "", schedule.startTime(DayPhase.NIGHT, d, now.zone) ?: ""),
                    fontSize = 12.sp, color = Palette.secondary)
            }
            // 時間軸色段。
            Spacer(Modifier.height(8.dp))
            Row(Modifier.fillMaxWidth().height(10.dp).clip(RoundedCornerShape(5.dp))) {
                for (s in schedule.segments(now.toLocalDate(), now.zone)) {
                    if (s.end > s.start) Box(Modifier.weight((s.end - s.start).toFloat()).fillMaxHeight().background(phaseColor(s.phase)))
                }
            }
        }
        Spacer(Modifier.height(24.dp))
    }
    // 場景生成完成後更新預覽。
    val finished by Jobs.finished.collectAsState()
    if (finished != null || running == null) {
        val id = prefs.dynamicSceneID
        if (id != sceneID) sceneID = id
    }
}

private fun kotlinx.coroutines.CoroutineScope.launchAuto(ctx: android.content.Context) {
    this.launch(kotlinx.coroutines.Dispatchers.IO) {
        Jobs.runDynamicAuto(ctx.applicationContext, manual = true)?.let { Jobs.finished.value = it.map { "scene" to 4 } }
    }
}

private fun phaseColor(p: DayPhase) = when (p) {
    DayPhase.DAWN -> androidx.compose.ui.graphics.Color(0xFFFF9F7A)
    DayPhase.DAY -> androidx.compose.ui.graphics.Color(0xFF64D2FF)
    DayPhase.DUSK -> androidx.compose.ui.graphics.Color(0xFFFF9F0A)
    DayPhase.NIGHT -> androidx.compose.ui.graphics.Color(0xFF3A3F7A)
}
