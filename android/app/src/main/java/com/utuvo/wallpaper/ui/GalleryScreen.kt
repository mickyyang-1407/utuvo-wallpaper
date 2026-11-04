package com.utuvo.wallpaper.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.utuvo.wallpaper.R
import com.utuvo.wallpaper.core.GalleryFilter
import com.utuvo.wallpaper.core.OverviewFacts
import com.utuvo.wallpaper.core.WallpaperLibrary
import com.utuvo.wallpaper.platform.AppClock
import com.utuvo.wallpaper.platform.Jobs

@Composable
fun GalleryScreen(model: AppModel, open: (String, List<String>) -> Unit) {
    val ctx = LocalContext.current
    var showGenerate by remember { mutableStateOf(false) }
    val running by Jobs.running.collectAsState()
    val visible = WallpaperLibrary.filter(model.items, model.filter, model.favorites)
    val present = model.items.map { it.category }.toSet()
    val filters = GalleryFilter.allFilters(model.env.data).filter { it !is GalleryFilter.Category || it.name in present }

    LazyVerticalGrid(
        columns = GridCells.Fixed(2),
        modifier = Modifier.fillMaxSize().testTag("gallery-grid"),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(span = { GridItemSpan(2) }) {
            Row(Modifier.statusBarsPadding().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.tab_gallery), fontSize = 30.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                Button({ showGenerate = true }, colors = ButtonDefaults.buttonColors(containerColor = Palette.accent),
                    modifier = Modifier.testTag("generate-button")) {
                    Icon(Icons.Filled.Add, null); Spacer(Modifier.width(4.dp)); Text(stringResource(R.string.generate))
                }
            }
        }
        item(span = { GridItemSpan(2) }) { Overview(model) { model.filter = GalleryFilter.Category(it) } }
        running?.let { r ->
            item(span = { GridItemSpan(2) }) {
                GlassCard {
                    Text(if (r.kind == "daily") stringResource(R.string.daily_progress, r.done, r.total)
                    else stringResource(R.string.generating_progress, r.done, r.total), fontSize = 14.sp)
                    Spacer(Modifier.height(8.dp))
                    LinearProgressIndicator({ if (r.total > 0) r.done / r.total.toFloat() else 0f }, Modifier.fillMaxWidth(), color = Palette.accent)
                    if (r.kind != "daily") {
                        androidx.compose.material3.TextButton({ Jobs.cancelGenerate(ctx) }, Modifier.testTag("cancel-generate")) {
                            Text(stringResource(R.string.cancel), color = Palette.red)
                        }
                    }
                }
            }
        }
        item(span = { GridItemSpan(2) }) {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(filters, key = { it.id }) { f ->
                    val label = when (f) {
                        GalleryFilter.All -> stringResource(R.string.filter_all)
                        GalleryFilter.Favorites -> stringResource(R.string.filter_favorites)
                        is GalleryFilter.Category -> Strings.core(ctx, f.name)
                    }
                    FilterChip(model.filter == f, { model.filter = f }, { Text(label) },
                        colors = FilterChipDefaults.filterChipColors(selectedContainerColor = Palette.accent.copy(alpha = 0.3f),
                            selectedLabelColor = Color.White, containerColor = Palette.cardFill, labelColor = Palette.secondary),
                        border = null, modifier = Modifier.testTag("filter-${f.id}"))
                }
            }
        }
        if (visible.isEmpty()) {
            item(span = { GridItemSpan(2) }) {
                Text(stringResource(if (model.filter == GalleryFilter.Favorites) R.string.empty_favorites else R.string.empty_category),
                    color = Palette.secondary, modifier = Modifier.padding(vertical = 32.dp))
            }
        }
        items(visible, key = { it.id }) { item ->
            Column(Modifier.clip(RoundedCornerShape(16.dp)).background(Palette.cardFill)
                .border(1.dp, Palette.cardStroke, RoundedCornerShape(16.dp))
                .clickable { open(item.id, visible.map { it.id }) }.testTag("card-${item.id}")) {
                Box {
                    WallpaperImage(ctx, item, 540, Modifier.fillMaxWidth().aspectRatio(9f / 19.5f), revision = model.revision)
                    if (item.id in model.favorites) {
                        Icon(Icons.Filled.Favorite, null, tint = Palette.pink, modifier = Modifier.align(Alignment.TopEnd).padding(8.dp))
                    }
                }
                Column(Modifier.padding(horizontal = 10.dp, vertical = 8.dp)) {
                    Text(model.title(item), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(if (item.isDemo) stringResource(R.string.demo) else Strings.core(ctx, item.category),
                        fontSize = 11.sp, color = Palette.secondary, maxLines = 1)
                }
            }
        }
    }
    if (showGenerate) GenerateSheet(model) { showGenerate = false }
}

@OptIn(ExperimentalLayoutApi::class)
/** 總覽：今天新增幾張＋分類分布條（實心＝今天新的，淡色＝之前的）。 */
@Composable
private fun Overview(model: AppModel, openCategory: (String) -> Unit) {
    val ctx = LocalContext.current
    val now = AppClock.now(ctx)
    val segments = OverviewFacts.segments(model.env.data, model.items, now)
    val total = segments.sumOf { it.total }.coerceAtLeast(1)
    GlassCard(Modifier.testTag("overview")) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(stringResource(R.string.today_new, OverviewFacts.todayNew(model.items, now)), fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            Text(stringResource(R.string.wallpapers_count, model.items.size), color = Palette.secondary, fontSize = 13.sp)
        }
        Spacer(Modifier.height(12.dp))
        Row(Modifier.fillMaxWidth().height(22.dp).clip(RoundedCornerShape(6.dp)), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            for (s in segments) {
                val color = Palette.category(s.category)
                Row(Modifier.weight(s.total / total.toFloat()).fillMaxHeight().clickable { openCategory(s.category) }) {
                    if (s.newCount > 0) Box(Modifier.weight(s.newCount.toFloat()).fillMaxHeight().background(color))
                    if (s.oldCount > 0) Box(Modifier.weight(s.oldCount.toFloat()).fillMaxHeight().background(color.copy(alpha = 0.4f)))
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            for (s in segments) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.width(8.dp).height(8.dp).clip(RoundedCornerShape(2.dp)).background(Palette.category(s.category)))
                    Spacer(Modifier.width(4.dp))
                    Text("${Strings.core(ctx, s.category)} ${s.total}", fontSize = 11.sp, color = Palette.secondary)
                }
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(stringResource(R.string.overview_hint), fontSize = 11.sp, color = Palette.secondary)
    }
}
