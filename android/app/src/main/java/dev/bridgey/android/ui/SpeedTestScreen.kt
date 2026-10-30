package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.SpeedLink
import dev.bridgey.android.SpeedReport
import dev.bridgey.android.SpeedTestState
import dev.bridgey.android.SpeedVerdict
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

class SpeedTestActions(
    val back: () -> Unit = {},
    val start: (String) -> Unit = {},
    val stop: () -> Unit = {},
    val copy: (SpeedReport) -> Unit = {},
)

/** Settings > Privacy > Transfer speed (SpeedTest.kt): pick a Mac, run, read the result in plain words, copy it. */
@Composable
fun SpeedTestScreen(
    state: SpeedTestState,
    devices: List<Pair<String, String>>,
    actions: SpeedTestActions,
    listState: LazyListState = rememberLazyListState(),
) {
    val colors = BridgeyTheme.colors
    var chosen by rememberSaveable { mutableStateOf<String?>(null) }
    val target = devices.firstOrNull { it.first == chosen } ?: devices.firstOrNull()
    SettingsPage(stringResource(R.string.speed_title), actions.back, listState) {
        item(key = "intro") {
            Text(
                stringResource(R.string.speed_intro), style = BridgeyType.bodyText, color = colors.onSurface,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 16.dp),
            )
        }
        if (devices.isEmpty()) {
            item(key = "none") {
                Text(stringResource(R.string.speed_no_mac), style = BridgeyType.bodyText, color = colors.onSurfaceVariant, modifier = Modifier.padding(20.dp))
            }
        } else {
            if (devices.size > 1 && !state.running) {
                item(key = "devices") {
                    RowGroup {
                        devices.forEach { (id, name) ->
                            row { shape ->
                                ListRow(
                                    shape, name, null, BridgeyIcons.LaptopMac, if (id == target?.first) Tint.BLUE else Tint.NEUTRAL,
                                    compact = true, onClick = { chosen = id },
                                )
                            }
                        }
                    }
                }
            }
            item(key = "run") {
                Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (state.running) {
                        OutlinePillButton(stringResource(R.string.speed_stop), null, actions.stop)
                    } else {
                        GradientButton(
                            stringResource(R.string.speed_start, target?.second ?: ""), null, { target?.let { actions.start(it.first) } },
                            Modifier.weight(1f), height = 48.dp,
                        )
                    }
                }
            }
        }
        if (state.running) {
            item(key = "progress") {
                Column(Modifier.padding(horizontal = 20.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    LinearProgressIndicator(
                        progress = { state.progress.coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth().height(6.dp),
                        color = colors.primary, trackColor = colors.surface3, strokeCap = StrokeCap.Round, drawStopIndicator = {},
                    )
                    Text(liveText(state), style = BridgeyType.small, color = colors.onSurfaceVariant)
                }
            }
        }
        if (state.phase == SpeedTestState.Phase.FAILED) {
            item(key = "failed") {
                Text(failureText(state.failure), style = BridgeyType.bodyText, color = colors.warn, modifier = Modifier.padding(20.dp))
            }
        }
        val report = state.report
        if (state.phase == SpeedTestState.Phase.FINISHED && report != null) {
            item(key = "figures") {
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Figure(stringResource(R.string.speed_phone_to_mac), report.phoneToMac, Modifier.weight(1f))
                    Figure(stringResource(R.string.speed_mac_to_phone), report.macToPhone, Modifier.weight(1f))
                }
            }
            item(key = "details") {
                RowGroup(Modifier.padding(top = 8.dp)) {
                    row { shape -> ListRow(shape, stringResource(R.string.speed_round_trip), roundTripText(report), BridgeyIcons.Lan, Tint.NEUTRAL, compact = true) }
                    row { shape -> ListRow(shape, stringResource(R.string.speed_this_phone), phoneLinkText(report.phone), BridgeyIcons.Smartphone, Tint.NEUTRAL, compact = true) }
                    row { shape -> ListRow(shape, stringResource(R.string.speed_mac), linkText(report.mac), BridgeyIcons.LaptopMac, Tint.NEUTRAL, compact = true) }
                }
            }
            item(key = "verdict") {
                Text(verdictText(report.verdict), style = BridgeyType.bodyText, color = colors.onSurface, modifier = Modifier.padding(20.dp, 16.dp))
            }
            item(key = "copy") {
                Row(Modifier.padding(horizontal = 16.dp)) {
                    OutlinePillButton(stringResource(R.string.speed_copy), null, { actions.copy(report) })
                }
            }
        }
    }
}

@Composable
private fun Figure(title: String, bytesPerSecond: Double?, modifier: Modifier) {
    val colors = BridgeyTheme.colors
    Column(modifier.background(colors.surface2, RoundedCornerShape(16.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(title, style = BridgeyType.small, color = colors.onSurfaceVariant)
        Text(
            bytesPerSecond?.let { stringResource(R.string.speed_mbps, it / 1_000_000) } ?: stringResource(R.string.speed_none),
            style = BridgeyType.rowTitle, color = colors.onSurface,
        )
    }
}

@Composable
private fun liveText(state: SpeedTestState): String = when (state.phase) {
    SpeedTestState.Phase.CONNECTING -> stringResource(R.string.speed_phase_connecting)
    SpeedTestState.Phase.ROUND_TRIPS -> stringResource(R.string.speed_phase_round_trips)
    SpeedTestState.Phase.SENDING -> stringResource(R.string.speed_phase_sending, stringResource(R.string.speed_mbps, state.liveBytesPerSecond / 1_000_000))
    SpeedTestState.Phase.RECEIVING -> stringResource(R.string.speed_phase_receiving)
    else -> ""
}

@Composable
private fun failureText(reason: String?): String = stringResource(
    when (reason) {
        "cancelled" -> R.string.speed_failed_cancelled
        "busy" -> R.string.speed_failed_busy
        "disconnected" -> R.string.speed_failed_disconnected
        "noAnswer" -> R.string.speed_failed_no_answer
        else -> R.string.speed_failed
    },
)

@Composable
private fun roundTripText(report: SpeedReport): String {
    val idle = report.roundTripMs
    val loaded = report.loadedRoundTripMs
    return when {
        idle != null && loaded != null -> stringResource(R.string.speed_round_trip_both, idle, loaded)
        idle != null -> stringResource(R.string.speed_round_trip_idle, idle)
        loaded != null -> stringResource(R.string.speed_round_trip_loaded, loaded)
        else -> stringResource(R.string.speed_unknown)
    }
}

@Composable
private fun linkText(link: SpeedLink?): String {
    link ?: return stringResource(R.string.speed_unknown)
    when (link.network) {
        "ethernet" -> return stringResource(R.string.speed_link_ethernet)
        "other" -> return stringResource(R.string.speed_link_other)
    }
    val parts = buildList {
        if (link.network == "hotspot") add(stringResource(R.string.speed_link_hotspot))
        add(link.standard?.let { "Wi-Fi $it" } ?: "Wi-Fi")
        link.band?.let { add(stringResource(R.string.speed_link_band, it)) }
        link.widthMhz?.let { add(stringResource(R.string.speed_link_width, it)) }
        link.linkMbps?.let { add(stringResource(R.string.speed_link_rate, it)) }
    }
    return parts.joinToString(", ")
}

@Composable
private fun phoneLinkText(link: SpeedLink): String {
    val lock = when {
        link.lockHeld == false -> stringResource(R.string.speed_lock_not_held)
        link.screenOn == false -> stringResource(R.string.speed_lock_screen_off)
        link.lockHeld == true -> stringResource(R.string.speed_lock_held)
        else -> null
    }
    return listOfNotNull(linkText(link), lock).joinToString(". ")
}

@Composable
private fun verdictText(verdict: SpeedVerdict): String {
    val lines = mutableListOf<String>()
    lines += stringResource(
        when (verdict.route) {
            SpeedVerdict.Route.SAME_ROUTER -> R.string.speed_route_same_router
            SpeedVerdict.Route.MAC_WIRED -> R.string.speed_route_mac_wired
            SpeedVerdict.Route.HOTSPOT -> R.string.speed_route_hotspot
            SpeedVerdict.Route.UNKNOWN -> R.string.speed_route_unknown
        },
    )
    when (verdict.basis) {
        SpeedVerdict.Basis.LINK_RATES -> lines += stringResource(R.string.speed_estimate_link_rates, verdict.expectedLow, verdict.expectedHigh)
        SpeedVerdict.Basis.TYPICAL -> lines += stringResource(R.string.speed_estimate_typical, verdict.expectedLow, verdict.expectedHigh)
        SpeedVerdict.Basis.NONE -> Unit
    }
    if (verdict.basis != SpeedVerdict.Basis.NONE) {
        lines += stringResource(if (verdict.asExpected) R.string.speed_verdict_ok else R.string.speed_verdict_slow)
    }
    verdict.advice.forEach { advice ->
        lines += stringResource(
            when (advice) {
                SpeedVerdict.Advice.PHONE_24 -> R.string.speed_advice_phone24
                SpeedVerdict.Advice.MAC_24 -> R.string.speed_advice_mac24
                SpeedVerdict.Advice.SCREEN_OFF -> R.string.speed_advice_screen_off
                SpeedVerdict.Advice.WEAK_LINK -> R.string.speed_advice_weak
                SpeedVerdict.Advice.TRY_HOTSPOT -> R.string.speed_advice_hotspot
            },
        )
    }
    return lines.joinToString(" ")
}
