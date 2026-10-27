package dev.bridgey.android.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.R
import dev.bridgey.android.ui.BridgeyIcons
import dev.bridgey.android.ui.ListRow
import dev.bridgey.android.ui.Note
import dev.bridgey.android.ui.RowGroup
import dev.bridgey.android.ui.Tint
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.ScreenBackdrop
import kotlinx.coroutines.launch

/** The widget's optional setup (and reconfigure): which Mac it shows, or the one selected in Bridgey. */
class MacWidgetConfigureActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val appWidgetId = intent?.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
        val app = application as BridgeyApplication
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID || !app.isPrimaryUser) { finish(); return }
        val devices = app.pairing.trustedDevices.value
        fun choose(deviceId: String?) {
            WidgetTargets.set(this, appWidgetId, deviceId)
            lifecycleScope.launch {
                MacWidget.refresh(applicationContext)
                setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
                finish()
            }
        }
        setContent {
            BridgeyTheme {
                ScreenBackdrop(bandHeight = 0.dp) {
                    Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())) {
                        Text(
                            stringResource(R.string.widget_choose_title), style = BridgeyType.pageTitle, color = BridgeyTheme.colors.onSurface,
                            modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 24.dp, bottom = 12.dp),
                        )
                        RowGroup {
                            row { shape ->
                                ListRow(
                                    shape, stringResource(R.string.widget_follow_selected), stringResource(R.string.widget_follow_selected_detail),
                                    BridgeyIcons.Sync, Tint.BLUE, onClick = { choose(null) }, role = Role.Button,
                                )
                            }
                            devices.forEach { device ->
                                row { shape ->
                                    ListRow(shape, device.name, null, BridgeyIcons.LaptopMac, Tint.PURPLE, onClick = { choose(device.id) }, role = Role.Button)
                                }
                            }
                        }
                        if (devices.isEmpty()) Note(stringResource(R.string.widget_no_mac), Modifier.padding(start = 32.dp, end = 32.dp, top = 12.dp))
                    }
                }
            }
        }
    }
}
