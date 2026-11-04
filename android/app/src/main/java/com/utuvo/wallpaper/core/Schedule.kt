package com.utuvo.wallpaper.core

import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.IsoFields
import kotlin.math.acos
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong
import kotlin.math.sin
import kotlin.math.tan

/** 經緯度。 */
data class Coordinate(val latitude: Double, val longitude: Double) {
    /** 是否在合法範圍內。 */
    val isValid: Boolean get() = latitude in -90.0..90.0 && longitude in -180.0..180.0

    companion object {
        /** 用時區推估位置：表內城市優先，否則緯度 30°、經度＝UTC 偏移×15。 */
        fun estimate(data: PromptData, zone: ZoneId, at: Instant = Instant.now()): Coordinate {
            data.timeZoneCities[zone.id]?.let { return it }
            val hours = zone.rules.getOffset(at).totalSeconds.toDouble() / 3600
            return Coordinate(30.0, max(-180.0, min(180.0, hours * 15)))
        }
    }
}

/** 日出日落（NOAA 簡化公式）。Swift `SolarCalculator`。 */
object SolarCalculator {
    /** 日出、日落（當地從午夜起的分鐘數）。 */
    data class SunTimes(val sunrise: Int, val sunset: Int)

    /** 指定當地日期與時區；極晝極夜回 null。 */
    fun sunriseSunset(date: LocalDate, zone: ZoneId, coordinate: Coordinate): SunTimes? {
        val dayOfYear = date.dayOfYear
        val localNoon = ZonedDateTime.of(date, LocalTime.NOON, zone)
        val offsetMinutes = localNoon.offset.totalSeconds.toDouble() / 60
        val gamma = 2 * Math.PI / 365 * (dayOfYear - 1).toDouble()
        val eqTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma) -
            0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        val decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma) - 0.006758 * cos(2 * gamma) +
            0.000907 * sin(2 * gamma) - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        val lat = coordinate.latitude * Math.PI / 180
        val zenith = 90.833 * Math.PI / 180
        val cosHA = cos(zenith) / (cos(lat) * cos(decl)) - tan(lat) * tan(decl)
        if (cosHA !in -1.0..1.0) return null
        val ha = acos(cosHA) * 180 / Math.PI
        val noon = 720 - 4 * coordinate.longitude - eqTime + offsetMinutes
        return SunTimes(swiftRound(noon - 4 * ha), swiftRound(noon + 4 * ha))
    }

    /** Swift `.rounded()`：四捨五入、.5 遠離 0。 */
    private fun swiftRound(v: Double): Int = (if (v < 0) -((-v).roundToLong()) else v.roundToLong()).toInt()
}

/** 日夜四時段。 */
enum class DayPhase(val raw: String) {
    DAWN("dawn"), DAY("day"), DUSK("dusk"), NIGHT("night");

    /** 白天以外三段用 edits 換光線的提示詞。 */
    val relightPrompt: String get() = ScenePrompt.relight(raw, ScenePrompt.Canvas.PHONE)

    companion object {
        /** 固定時間：06–09 清晨、09–18 白天、18–21 黃昏，其餘夜晚。 */
        fun current(hour: Int): DayPhase = when (hour) {
            in 6 until 9 -> DAWN
            in 9 until 18 -> DAY
            in 18 until 21 -> DUSK
            else -> NIGHT
        }

        /** 從 raw 字串還原。 */
        fun of(raw: String): DayPhase? = entries.firstOrNull { it.raw == raw }

        /** 第一張（白天）的提示詞。 */
        fun basePrompt(scene: String): String = ScenePrompt.base(scene, ScenePrompt.Canvas.PHONE)
    }
}

/** 日夜切換方式。Android 沒有「跟系統外觀」以外的差異，三種都保留。 */
enum class DynamicTiming(val raw: String) {
    FIXED("fixed"), SOLAR("solar"), APPEARANCE("appearance");

    companion object {
        /** 從 raw 字串還原，未知值＝FIXED。 */
        fun of(raw: String?): DynamicTiming = entries.firstOrNull { it.raw == raw } ?: FIXED
    }
}

/** 一天裡四個時段的起點（分鐘）。Swift `DynamicSchedule`（iPhone 版，白天／黃昏偏移 60 分）。 */
data class DynamicSchedule(
    val timing: DynamicTiming,
    val coordinate: Coordinate,
    val daySideOffset: Int = PHONE_DAY_SIDE_OFFSET,
) {
    /** 下一個時段與開始時刻。 */
    data class Next(val phase: DayPhase, val at: ZonedDateTime)

    /** 時間軸色段。 */
    data class Segment(val phase: DayPhase, val start: Int, val end: Int)

    /** 當天四個起點；solar 算不出來或時段擠在一起時退回固定時間。 */
    fun starts(date: LocalDate, zone: ZoneId): Map<DayPhase, Int> {
        if (timing != DynamicTiming.SOLAR) return FIXED_STARTS
        val sun = SolarCalculator.sunriseSunset(date, zone, coordinate) ?: return FIXED_STARTS
        val ordered = listOf(sun.sunrise - 30, sun.sunrise + daySideOffset, sun.sunset - daySideOffset, sun.sunset + 30)
        if (ordered.first() < 0 || ordered.last() >= 1440 || ordered.zipWithNext().any { (a, b) -> a >= b }) return FIXED_STARTS
        return mapOf(DayPhase.DAWN to ordered[0], DayPhase.DAY to ordered[1], DayPhase.DUSK to ordered[2], DayPhase.NIGHT to ordered[3])
    }

    /** 目前時段；[isDark] 只有 appearance 模式會用。 */
    fun phase(at: ZonedDateTime, isDark: Boolean = false): DayPhase {
        if (timing == DynamicTiming.APPEARANCE) return if (isDark) DayPhase.NIGHT else DayPhase.DAY
        val s = starts(at.toLocalDate(), at.zone)
        val minute = minuteOfDay(at)
        if (minute >= s.getValue(DayPhase.NIGHT) || minute < s.getValue(DayPhase.DAWN)) return DayPhase.NIGHT
        if (minute >= s.getValue(DayPhase.DUSK)) return DayPhase.DUSK
        if (minute >= s.getValue(DayPhase.DAY)) return DayPhase.DAY
        return DayPhase.DAWN
    }

    /** 24 小時時間軸色段，夜晚跨午夜拆成頭尾兩段；appearance 回空。 */
    fun segments(date: LocalDate, zone: ZoneId): List<Segment> {
        if (timing == DynamicTiming.APPEARANCE) return emptyList()
        val s = starts(date, zone)
        return listOf(
            Segment(DayPhase.NIGHT, 0, s.getValue(DayPhase.DAWN)),
            Segment(DayPhase.DAWN, s.getValue(DayPhase.DAWN), s.getValue(DayPhase.DAY)),
            Segment(DayPhase.DAY, s.getValue(DayPhase.DAY), s.getValue(DayPhase.DUSK)),
            Segment(DayPhase.DUSK, s.getValue(DayPhase.DUSK), s.getValue(DayPhase.NIGHT)),
            Segment(DayPhase.NIGHT, s.getValue(DayPhase.NIGHT), 1440),
        )
    }

    /** 下一個時段與它開始的時刻（今天或明天），給 AlarmManager 排程用；appearance 回 null。 */
    fun next(after: ZonedDateTime): Next? {
        if (timing == DynamicTiming.APPEARANCE) return null
        val minute = minuteOfDay(after)
        val day = after.toLocalDate()
        fun at(minutes: Int, on: LocalDate) = ZonedDateTime.of(on, LocalTime.of(minutes / 60, minutes % 60), after.zone)
        starts(day, after.zone).entries.sortedBy { it.value }.firstOrNull { it.value > minute }?.let {
            return Next(it.key, at(it.value, day))
        }
        val tomorrow = day.plusDays(1)
        val first = starts(tomorrow, after.zone).entries.minBy { it.value }
        return Next(first.key, at(first.value, tomorrow))
    }

    /** 某時段今天的開始時間 "HH:mm"；appearance 回 null（介面顯示淺色／深色）。 */
    fun startTime(phase: DayPhase, date: LocalDate, zone: ZoneId): String? =
        if (timing == DynamicTiming.APPEARANCE) null else clock(starts(date, zone).getValue(phase))

    companion object {
        const val PHONE_DAY_SIDE_OFFSET = 60
        val FIXED_STARTS: Map<DayPhase, Int> =
            mapOf(DayPhase.DAWN to 360, DayPhase.DAY to 540, DayPhase.DUSK to 1080, DayPhase.NIGHT to 1260)

        /** 從午夜起的分鐘數。 */
        fun minuteOfDay(t: ZonedDateTime): Int = t.hour * 60 + t.minute

        /** 分鐘 → "HH:mm"（可跨日、負數）。 */
        fun clock(minutes: Int): String {
            val m = ((minutes % 1440) + 1440) % 1440
            return "%02d:%02d".format(m / 60, m % 60)
        }
    }
}

/** 日夜 AI 自動頻率。 */
enum class DynamicAutoFrequency(val raw: String) {
    OFF("off"), DAILY("daily"), WEEKLY("weekly");

    companion object {
        /** 從 raw 字串還原，未知值＝OFF。 */
        fun of(raw: String?): DynamicAutoFrequency = entries.firstOrNull { it.raw == raw } ?: OFF
    }
}

/** 季節（小寫名稱與 Swift `"\(season)"` 相同）。 */
enum class Season { SPRING, SUMMER, AUTUMN, WINTER;
    /** 與 Swift 列舉名稱相同的小寫字串。 */
    val raw: String get() = name.lowercase()
}

/**
 * 自動場景的進度（Swift `DynamicAutoState`）。付費請求送出前先記 attempts。
 * [retryAfterEpochMs] 為 null 代表不用等。
 */
data class DynamicAutoState(
    val period: String,
    val subject: String,
    val prompt: String,
    val sceneID: String,
    val attempts: Int = 0,
    val retryAfterEpochMs: Long? = null,
    val completed: Boolean = false,
    val recentSubjects: List<String> = emptyList(),
) {
    /** 生成失敗：可重試的 30 分鐘後再試，其他錯誤這一期不再自動試。 */
    fun recordFailure(retryable: Boolean, nowMs: Long): DynamicAutoState =
        if (retryable && attempts < MAX_ATTEMPTS) copy(retryAfterEpochMs = nowMs + RETRY_DELAY_MS)
        else copy(attempts = MAX_ATTEMPTS)

    /** 成功：標完成、記進最近主題。 */
    fun recordSuccess(): DynamicAutoState =
        copy(completed = true, retryAfterEpochMs = null,
            recentSubjects = (recentSubjects + subject).takeLast(DynamicAutoPlanner.RECENT_LIMIT))

    companion object {
        const val MAX_ATTEMPTS = 3
        const val RETRY_DELAY_MS = 30L * 60 * 1000
    }
}

/** 日夜 AI 自動挑題（Swift `DynamicAutoPlanner`）。 */
object DynamicAutoPlanner {
    const val RECENT_LIMIT = 6

    /** 挑題結果。 */
    data class Pick(val subject: String, val prompt: String)

    /** 這一期的代號：每天＝yyyy-MM-dd，每週＝ISO 週 yyyy-Www；關閉回 null。 */
    fun period(at: ZonedDateTime, frequency: DynamicAutoFrequency): String? = when (frequency) {
        DynamicAutoFrequency.OFF -> null
        DynamicAutoFrequency.DAILY -> "%04d-%02d-%02d".format(at.year, at.monthValue, at.dayOfMonth)
        DynamicAutoFrequency.WEEKLY ->
            "%04d-W%02d".format(at.get(IsoFields.WEEK_BASED_YEAR), at.get(IsoFields.WEEK_OF_WEEK_BASED_YEAR))
    }

    /** 季節；南半球月份位移 6 個月。 */
    fun season(at: ZonedDateTime, southern: Boolean = false): Season {
        var month = at.monthValue
        if (southern) month = (month + 5) % 12 + 1
        return when (month) {
            in 3..5 -> Season.SPRING
            in 6..8 -> Season.SUMMER
            in 9..11 -> Season.AUTUMN
            else -> Season.WINTER
        }
    }

    /** 挑主題：同一期結果固定；避開最近用過的、冬季限定只在冬天出現。 */
    fun pick(data: PromptData, period: String, salt: Long = 0, season: Season, recent: List<String>, chinese: Boolean): Pick {
        val seasonal = data.autoSubjects.filter { !it.winterOnly || season == Season.WINTER }
        val fresh = seasonal.filter { it.id !in recent }
        val pool = fresh.ifEmpty { seasonal }
        val hash = StableHash.of("$period#$salt")
        val subject = pool[(hash % pool.size.toULong()).toInt()]
        val weather = data.autoWeathers[((hash shr 20) % data.autoWeathers.size.toULong()).toInt()]
        val style = data.autoStyles[((hash shr 40) % data.autoStyles.size.toULong()).toInt()]
        val seasonText = when (season) {
            Season.SPRING -> ZhEn("春天", "spring")
            Season.SUMMER -> ZhEn("夏天", "summer")
            Season.AUTUMN -> ZhEn("秋天", "autumn")
            Season.WINTER -> ZhEn("冬天", "winter")
        }
        val prompt = if (chinese) "${subject.zh}，${seasonText.zh}，${weather.zh}，${style.zh}"
        else "${subject.en}, ${seasonText.en}, ${weather.en}, ${style.en}"
        return Pick(subject.id, prompt)
    }

    /** 場景 id：`ai-<period>-<hash % 1000000>`。 */
    fun sceneID(period: String, salt: Long, subject: String): String =
        "ai-$period-${StableHash.of("$period#$salt#$subject") % 1_000_000uL}"

    /** 排程：到期就回傳要做的狀態（新的一期或續作），否則 null。 */
    fun due(data: PromptData, state: DynamicAutoState?, now: ZonedDateTime, frequency: DynamicAutoFrequency,
            southern: Boolean = false, chinese: Boolean): DynamicAutoState? {
        val period = period(now, frequency) ?: return null
        if (state != null && state.period == period) {
            if (state.completed || state.attempts >= DynamicAutoState.MAX_ATTEMPTS) return null
            val retry = state.retryAfterEpochMs
            if (retry != null && retry > now.toInstant().toEpochMilli()) return null
            return state
        }
        return fresh(data, period, 0, state, now, southern, chinese)
    }

    /** 手動「現在生成一組」：沒做完就續作；這期已完成就換主題重來。 */
    fun manual(data: PromptData, state: DynamicAutoState?, now: ZonedDateTime, frequency: DynamicAutoFrequency,
               southern: Boolean = false, chinese: Boolean): DynamicAutoState {
        val period = period(now, if (frequency == DynamicAutoFrequency.OFF) DynamicAutoFrequency.DAILY else frequency) ?: "manual"
        if (state != null && state.period == period && !state.completed) {
            return state.copy(attempts = min(state.attempts, DynamicAutoState.MAX_ATTEMPTS - 1), retryAfterEpochMs = null)
        }
        val salt = if (state?.period == period) now.toEpochSecond() else 0L
        return fresh(data, period, salt, state, now, southern, chinese)
    }

    private fun fresh(data: PromptData, period: String, salt: Long, previous: DynamicAutoState?, now: ZonedDateTime,
                      southern: Boolean, chinese: Boolean): DynamicAutoState {
        var recent = previous?.recentSubjects ?: emptyList()
        if (previous != null && !previous.completed) recent = (recent + previous.subject).takeLast(RECENT_LIMIT)
        val choice = pick(data, period, salt, season(now, southern), recent, chinese)
        return DynamicAutoState(period, choice.subject, choice.prompt, sceneID(period, salt, choice.subject),
            recentSubjects = recent)
    }
}
