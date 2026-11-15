package dev.bridgey.android.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import dev.bridgey.android.R
import dev.bridgey.android.VersionNames
import dev.bridgey.android.VersionWords
import java.text.DateFormatSymbols

/** Version labels in the app's language: "1.0 Beta 2", "1.0 Nightly 16 Nov" (VersionNames in UpdateLogic.kt). */
@Composable
fun versionWords(): VersionWords {
    val beta = stringResource(R.string.channel_beta)
    val nightly = stringResource(R.string.channel_nightly)
    val locale = LocalConfiguration.current.locales[0]
    return remember(beta, nightly, locale) {
        val months = DateFormatSymbols.getInstance(locale).shortMonths.filter { it.isNotEmpty() }.map { it.trimEnd('.') }
        VersionWords(beta, nightly, months.takeIf { it.size == 12 } ?: VersionWords().months)
    }
}

/** The label people see for a version: "1.0 Beta 2". */
@Composable
fun versionLabel(name: String): String = VersionNames.label(name, versionWords())

/** [versionLabel], or "Beta 3" when [other] is a build of the same release. */
@Composable
fun shortVersionLabel(name: String, other: String): String = VersionNames.short(name, other, versionWords())
