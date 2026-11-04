package com.utuvo.wallpaper.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.utuvo.wallpaper.R
import com.utuvo.wallpaper.core.WallpaperLibrary
import com.utuvo.wallpaper.platform.DeviceScreen

/** 大圖頁：HorizontalPager 左右滑換上一張／下一張；清單＝進來時圖庫的篩選結果。 */
@Composable
fun DetailScreen(model: AppModel, startID: String, close: () -> Unit) {
    val ctx = LocalContext.current
    val alive = model.items.associateBy { it.id }
    val pages = model.detailIDs.ifEmpty { listOf(startID) }.mapNotNull { alive[it] }
    if (pages.isEmpty()) { LaunchedEffect(Unit) { close() }; return }
    var currentID by remember { mutableStateOf(startID) }
    val startIndex = pages.indexOfFirst { it.id == currentID }.coerceAtLeast(0)
    val pager = rememberPagerState(initialPage = startIndex) { pages.size }
    var confirmDelete by remember { mutableStateOf(false) }

    LaunchedEffect(pager, pages.size) {
        snapshotFlow { pager.currentPage }.collect { p -> pages.getOrNull(p)?.let { currentID = it.id } }
    }
    // 刪除後清單變短：跳到 currentID 那一頁。
    LaunchedEffect(currentID, pages.size) {
        val i = pages.indexOfFirst { it.id == currentID }
        if (i >= 0 && i != pager.currentPage) pager.scrollToPage(i)
    }
    val item = pages.getOrNull(pager.currentPage.coerceIn(0, pages.size - 1)) ?: pages[0]
    val isFavorite = item.id in model.favorites
    val isPinned = model.pinnedID == item.id
    val (w, h) = remember { DeviceScreen.nativePixels(ctx) }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        HorizontalPager(pager, Modifier.fillMaxSize().testTag("detail-pager"), key = { pages[it].id }) { page ->
            WallpaperImage(ctx, pages[page], 1600, Modifier.fillMaxSize(), scale = ContentScale.Crop, revision = model.revision)
        }
        Row(Modifier.statusBarsPadding().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(close, Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.35f)).testTag("detail-back")) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, null, tint = Color.White)
            }
            Spacer(Modifier.width(8.dp))
            Text(model.title(item), color = Color.White, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.clip(RoundedCornerShape(12.dp)).background(Color.Black.copy(alpha = 0.35f)).padding(horizontal = 10.dp, vertical = 6.dp))
        }
        Column(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                RoundButton(if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                    stringResource(if (isFavorite) R.string.favorited else R.string.favorite), if (isFavorite) Palette.pink else Color.White, "favorite") {
                    model.toggleFavorite(item)
                }
                RoundButton(if (isPinned) Icons.Filled.Star else Icons.Outlined.Star,
                    stringResource(if (isPinned) R.string.pinned else R.string.pin), if (isPinned) Palette.green else Color.White, "pin") {
                    model.togglePin(item)
                }
                RoundButton(Icons.Filled.KeyboardArrowDown, stringResource(R.string.save_photos), Color.White, "save") { model.saveToPhotos(item) }
                RoundButton(Icons.Filled.Share, stringResource(R.string.share), Color.White, "share") {
                    model.shareIntent(item)?.let { ctx.startActivity(it) }
                }
                if (!item.isDemo) RoundButton(Icons.Filled.Delete, stringResource(R.string.delete), Palette.red, "delete") { confirmDelete = true }
            }
            Spacer(Modifier.size(12.dp))
            // 底列：分類＋「2／26」＋解析度＋設為桌布。
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(50)).background(Color(0xE61C2028))
                .border(1.dp, Palette.cardStroke, RoundedCornerShape(50)).padding(6.dp).padding(start = 4.dp),
                verticalAlignment = Alignment.CenterVertically) {
                IconTile(Strings.core(ctx, item.category).take(1), Palette.category(item.category))
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(if (item.isDemo) stringResource(R.string.demo) else Strings.core(ctx, item.category),
                            fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                        if (pages.size > 1) {
                            Spacer(Modifier.width(6.dp))
                            Text(stringResource(R.string.page_count, pager.currentPage + 1, pages.size), fontSize = 12.sp,
                                color = Palette.secondary, modifier = Modifier.testTag("page-count"))
                        }
                    }
                    Text("$w×$h", fontSize = 12.sp, color = Palette.secondary)
                }
                Button({ model.setAsWallpaper(item) }, colors = ButtonDefaults.buttonColors(containerColor = Palette.accent),
                    modifier = Modifier.testTag("set-wallpaper")) { Text(stringResource(R.string.set_wallpaper)) }
            }
        }
    }
    if (confirmDelete) {
        AlertDialog(onDismissRequest = { confirmDelete = false }, title = { Text(stringResource(R.string.delete_confirm)) },
            confirmButton = {
                TextButton({
                    confirmDelete = false
                    val next = WallpaperLibrary.neighborID(item.id, pages.map { it.id })
                    model.delete(item)
                    if (next != null) currentID = next else close()
                }, modifier = Modifier.testTag("confirm-delete")) { Text(stringResource(R.string.delete), color = Palette.red) }
            },
            dismissButton = { TextButton({ confirmDelete = false }) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun RoundButton(icon: ImageVector, label: String, tint: Color, tag: String, run: () -> Unit) {
    Box(Modifier.size(48.dp).clip(CircleShape).background(Color(0xCC1C2028)).border(1.dp, Palette.cardStroke, CircleShape)
        .clickable(onClick = run).semantics { contentDescription = label }.testTag("detail-$tag"), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = tint)
    }
}
