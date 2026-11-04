package com.utuvo.wallpaper.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.utuvo.wallpaper.R
import com.utuvo.wallpaper.core.DailyRecipe
import com.utuvo.wallpaper.core.PromptInspiration
import com.utuvo.wallpaper.platform.Jobs

/** 產生桌布面板：張數 1–10、分類、自己的 Prompt、AI 靈感。 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun GenerateSheet(model: AppModel, dismiss: () -> Unit) {
    val ctx = LocalContext.current
    val data = model.env.data
    val saved = remember { model.env.prefs.recipe(data, DailyRecipe.MANUAL_PREFIX) }
    var recipe by remember { mutableStateOf(saved) }
    var count by remember { mutableIntStateOf(4) }
    var error by remember { mutableStateOf<String?>(null) }
    val running by Jobs.running.collectAsState()
    val picked = recipe.categories(data)

    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Color(0xFF1C2028)) {
        Column(Modifier.padding(horizontal = 20.dp).navigationBarsPadding().verticalScroll(rememberScrollState()).testTag("generate-sheet")) {
            Text(stringResource(R.string.generate), fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(16.dp))
            val r = running
            if (r != null) {
                Text(stringResource(R.string.generating_title), fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                LinearProgressIndicator({ if (r.total > 0) r.done / r.total.toFloat() else 0f }, Modifier.fillMaxWidth(), color = Palette.accent)
                Spacer(Modifier.height(6.dp))
                Text(stringResource(R.string.generating_progress, r.done, r.total), color = Palette.secondary, fontSize = 13.sp)
                Text(stringResource(R.string.can_close), color = Palette.secondary, fontSize = 13.sp)
                Spacer(Modifier.height(12.dp))
                Row {
                    if (r.cancellable) {
                        TextButton({ Jobs.cancelGenerate(ctx) }, Modifier.testTag("cancel-generate")) {
                            Text(stringResource(R.string.cancel), color = Palette.red)
                        }
                    }
                    TextButton(dismiss) { Text(stringResource(R.string.close)) }
                }
                Spacer(Modifier.height(24.dp))
                return@Column
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.count), modifier = Modifier.weight(1f))
                Text(pluralStringResource(R.plurals.wallpapers_count, count, count), color = Palette.secondary)
            }
            Slider(count.toFloat(), { count = it.toInt().coerceIn(1, 10) }, valueRange = 1f..10f, steps = 8,
                colors = SliderDefaults.colors(thumbColor = Palette.accent, activeTrackColor = Palette.accent), modifier = Modifier.testTag("count-slider"))
            Spacer(Modifier.height(8.dp))
            Row {
                Text(stringResource(R.string.category), modifier = Modifier.weight(1f))
                Text(if (picked.isEmpty()) stringResource(R.string.all_categories) else pluralStringResource(R.plurals.n_categories, picked.size, picked.size), color = Palette.secondary)
            }
            Spacer(Modifier.height(8.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(picked.isEmpty(), { recipe = recipe.copy(styles = emptyList()) }, { Text(stringResource(R.string.all_categories)) },
                    colors = chipColors())
                for (c in data.categories) {
                    val on = c in picked
                    FilterChip(on, { recipe = recipe.withCategory(data, c, !on) }, { Text(Strings.core(ctx, c)) }, colors = chipColors(),
                        modifier = Modifier.testTag("cat-$c"))
                }
            }
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(recipe.idea, { recipe = recipe.copy(idea = it.take(DailyRecipe.IDEA_LIMIT)) }, Modifier.fillMaxWidth(),
                label = { Text(stringResource(R.string.own_prompt)) }, placeholder = { Text(stringResource(R.string.prompt_example), fontSize = 13.sp) },
                minLines = 2)
            TextButton({
                recipe = recipe.copy(idea = PromptInspiration.pick(data, recipe.categories(data), recipe.idea, Strings.isChinese(ctx)))
            }, modifier = Modifier.testTag("ai-idea")) { Text("✦ " + stringResource(R.string.ai_idea)) }
            Text(stringResource(R.string.generate_note), color = Palette.secondary, fontSize = 12.sp)
            error?.let { Spacer(Modifier.height(8.dp)); Text(it, color = Palette.orange, fontSize = 13.sp) }
            Spacer(Modifier.height(16.dp))
            Button({ error = model.startManual(count, recipe) }, Modifier.fillMaxWidth().testTag("start-generate"),
                colors = ButtonDefaults.buttonColors(containerColor = Palette.accent)) {
                Text(stringResource(R.string.generate_n, count))
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
internal fun chipColors() = FilterChipDefaults.filterChipColors(selectedContainerColor = Palette.accent.copy(alpha = 0.3f),
    selectedLabelColor = Color.White, containerColor = Palette.cardFill, labelColor = Palette.secondary)
