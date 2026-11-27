# Accessibility and localisation review, 1.0

What we checked in the Mac and Android apps of Bridgey by Round Robin before 1.0 for people who use VoiceOver,
TalkBack, the keyboard, larger text or Reduce motion, and for people who use the apps in Russian. It covers `rr/main` at
`a85698c6` (Beta 11, 2026-11-26): the six-group Settings, unattended access and screen sharing included. It is the
companion to the [security review](security-review-1.0.md) and, like it, our own review of our own code.

## Scope and method

- **Accessibility:** a name, role and state for every control with VoiceOver and TalkBack (switches, device chips,
  More options, icon-only buttons, the Transfers window, the screen viewer and its bars, the call card, the code float,
  the menu bar panel); focus and reading order; the whole Mac app from the keyboard (Tab and Shift-Tab, Escape closes,
  Return presses the default button); Android font scale up to 200% and touch targets of at least 48 dp; contrast of
  at least 4.5:1 for text and 3:1 for controls in light and dark, from the tokens in `BrandTheme.swift` and the Android
  theme; Reduce motion; nothing said by colour alone.
- **Localisation:** every word on screen from the string tables, English and Russian complete, real plural forms,
  dates, times, sizes and speeds in the user's locale, no sentences glued together, Russian (about 30% longer) fitting,
  and English that is British, plain and short, with no em dashes, eyebrow labels or subheads that repeat a heading.
- **How:** source scans for each pattern (tap gestures, icon-only buttons, literals in views, fixed sizes, colours,
  animations), then reading every hit; contrast computed from the tokens; the Mac app's surfaces drawn in English and
  Russian, light and dark, before and after; Android screens drawn under Robolectric at 100% and 200% text and checked with
  Google's Accessibility Test Framework (ATF). One reviewer per platform; the lead reviewed the Mac, checked the
  Android findings against the diff and wrote this report.

Severity:

- **High:** a core task cannot be done with a screen reader, the keyboard or large text, text is unreadable, or a core
  flow shows raw keys or English in Russian.
- **Medium:** possible but hard: a control without a name or state, text cut at large sizes, text contrast between 3
  and 4.5:1, a control under 3:1, wrong plurals, English in a visible place in Russian.
- **Low:** polish.
- **Info:** checked, no change needed.

Paths are relative to `macos/Sources/BridgeyMac/` (Mac) and `android/app/src/main/java/dev/bridgey/android/` (Android)
unless they start at the repository root. Line numbers are from `a85698c6`. IDs: MA Mac accessibility, ML Mac
localisation and copy, AA Android accessibility, AL Android localisation and copy.

## Summary

| | Found | Fixed in this branch | Open |
| --- | --- | --- | --- |
| High | 4 | 4 | 0 |
| Medium | 16 | 16 | 0 |
| Low | 15 | 13 | 1, plus 1 won't do |

Ten more checks found nothing to change ([Checked and found sound](#checked-and-found-sound)). The open items are
The follow-up PR fixed three more and settled the rest ([Follow-up](#follow-up)): the Siri phrases stay English and
larger text on the Mac is not planned for 1.0. Nothing here changes the wire protocol.

On the base tree, the new Android check counted 92 switches with no state, 75 nodes read twice, 49 cut texts and two
ATF errors; after the fixes it counts none. The new Mac checks found six unlabelled icon buttons and two keys the code
used that neither language had.

| ID | Severity | App | Finding | Status |
| --- | --- | --- | --- | --- |
| MA1 | High | Mac | Settings switches could not be reached or turned with the keyboard | Fixed |
| AA1 | High | Android | Switches did not say whether they were on | Fixed |
| AL1 | High | Android | File progress and transfer results were English, in a US format | Fixed |
| AL2 | High | Android | Snackbars and toasts were English | Fixed |
| MA2 | Medium | Mac | Card switches and device chips said their state in English, as buttons | Fixed |
| MA3 | Medium | Mac | Icon-only buttons were read by their symbol names | Fixed |
| MA4 | Medium | Mac | Messages: conversations only with the mouse | Fixed |
| MA5 | Medium | Mac | Transfers: items only with the mouse | Fixed |
| MA6 | Medium | Mac | An empty checkbox outline was 1.3:1 | Fixed |
| ML2 | Medium | Mac | Status lines were English in Russian | Fixed |
| ML3 | Medium | Mac | Text hard-coded in views | Fixed |
| ML4 | Medium | Mac | Plurals | Fixed |
| AA2 | Medium | Android | Device chips read the device name twice | Fixed |
| AA3 | Medium | Android | Other things read twice | Fixed |
| AA4 | Medium | Android | Text cut at 200% | Fixed |
| AA5 | Medium | Android | Setup's main button lost its label at 200% | Fixed |
| AA6 | Medium | Android | The composer's Attach button was too small at 200% | Fixed |
| AL3 | Medium | Android | Dialogs, notifications and window titles were English | Fixed |
| AL4 | Medium | Android | Two actions had one Russian name | Fixed |
| AL5 | Medium | Android | Plurals | Fixed |
| MA7 | Low | Mac | Done-only sheets did not close with Escape | Fixed |
| MA8 | Low | Mac | A field named by its placeholder, headings, a symbol read twice | Fixed |
| ML1 | Low | Mac | Messages search used small tracked capitals | Fixed |
| ML5 | Low | Mac | Russian did not fit; a device name was cut | Fixed |
| ML6 | Low | Mac | Decimals in speeds used a full stop in Russian | Fixed |
| AA7 | Low | Android | Touch targets under 48 dp | Fixed |
| AA8 | Low | Android | Repeated names on one page | Fixed |
| AL6 | Low | Android | Speeds and percentages in the locale | Fixed |
| AL7 | Low | Android | The media card's default line was English | Fixed |
| AL8 | Low | Android | Setup questions had an uppercase eyebrow | Fixed |
| MA9 | Low | Mac | No larger text on the Mac | Won't do for 1.0 |
| ML7 | Low | Mac | The Siri phrases of the App Shortcuts are English only | Open |
| AA10 | Low | Android | Text field borders were 1.1:1 to 1.4:1 | Fixed |
| AA13 | Low | Android | Two Clear and two Allow buttons shared a name | Fixed |
| AL10 | Low | Android | Russian at 200% broke long words without a hyphen | Fixed |

## High

### MA1. Settings switches could not be reached or turned with the keyboard (Mac)

- **Where:** `BrandTheme.swift:410-433` (`BrandSwitchStyle`), used by `SettingsToggle` (`SettingsWindow.swift:813-830`,
  45 rows), setup, Agents and the Send options.
- **What:** the switch was a view with a tap gesture. Tab never reached it with Keyboard navigation on, Space did
  nothing, and VoiceOver called it a button. Its state was `Text("On")` or `Text("Off")`, which no table has, so it was
  English in Russian too.
- **Evidence:** code; the source check `testTapGesturesHaveAKeyboardWay` lists every remaining tap gesture.
- **Fix:** the switch is a plain `Button` around the row, so Tab reaches it and Space turns it on or off. VoiceOver
  hears a toggle (macOS 14 and later; a button on 13) and the state in the app's language (`action.on`,
  `action.off`: On, Off; Включено, Выключено). It looks the same.
- **Status:** Fixed.

### AA1. Switches did not say whether they were on (Android)

- **Where:** `ui/Components.kt:304-335` (`SwitchRow`, semantics at `:327`), `ui/SettingsCards.kt:312-327` (card header
  switch), `ui/AgentScreens.kt:345-363` (agent grant rows).
- **What:** the row has the switch role, but the switch inside has no click of its own (`onCheckedChange = null`), so
  nothing reported its state. TalkBack said "Switch" with no on or off on every feature switch.
- **Evidence:** `AccessibilityChecksTest` on the base tree counted 92 switches with no state across Settings, setup and
  the device pages.
- **Fix:** the row's semantics carry `toggleableState(checked)`.
- **Status:** Fixed.

### AL1. File progress and transfer results were English, in a US format (Android)

- **Where:** `PairingCoordinator.kt:7083-7131` (`TransferProgress`) and the transfer statuses at `:3300-3833` and
  `:4579-5378`; `ui/Stream.kt:667`; `BridgeyConnectionService.kt:162`, `:250`.
- **What:** progress was built in English with `Locale.US` ("45% · 1.2 MB / 30 MB · 3 MB/s · 2 min 5 sec left",
  "calculating…"), and about 25 results ("Transfer cancelled", "File verification failed") were literals. Russian
  users saw English on the transfer card and in the notification.
- **Fix:** `strings_status.xml` (new, English and Russian) and the localised size and duration helpers. The leading
  "45%" stays because the progress bar reads it back. `stopFileQueue` takes an explicit outcome instead of looking for
  "cancel" in the text, which would have broken in Russian.
- **Status:** Fixed.

### AL2. Snackbars and toasts were English (Android)

- **Where:** `PairingCoordinator.kt:1610-2043`, `:2370-2419`, `:4457-4518`; `QuickActions.kt:143-249`;
  `BridgeyConnectionService.kt:573-592`; `MainActivity.kt:621`, `:759`; `activity/ActivityRecorder.kt:113`.
- **What:** clipboard, ping, link and media messages were English literals, three with em dashes. The list of quiet
  messages compared English text, and recording a sent link depended on the words "Link delivered".
- **Fix:** all in the tables; the quiet list compares the resource text; a `QuickActions.linkDelivered` flow records
  the link.
- **Status:** Fixed.

## Medium

### MA2. Card switches and device chips said their state in English, as buttons (Mac)

- **Where:** `SettingsCards.swift:321-327` (card header), `:531-535` (`DeviceChoiceChipView`),
  `LocalAgentCodesView.swift:148` (used `action.on` and `action.off`, which neither table had).
- **What:** the state came from `Text("On")`/`Text("Off")` or from missing keys, so Russian VoiceOver users heard
  English. Every card header and chip also carried an empty hint, and chips read as "button, selected".
- **Fix:** the same toggle role and localised state as MA1; empty hints are gone; the chip is one element (name and
  feature once, then the state).
- **Status:** Fixed.

### MA3. Icon-only buttons were read by their symbol names (Mac)

- **Where:** the call card's hide button (`CallOverlayWindow.swift:359-367`), the Calls window's clear button
  (`CallsWindow.swift:432`), the SIM choice's cancel button (`:597`), the notice's dismiss button (`:684`), Phone files'
  refresh button (`PhoneFilesViews.swift:191`), the folder card's details chevron in the menu bar panel
  (`StreamPanel.swift:890-898`).
- **What:** each had only a symbol and a tooltip. `.help` is the tooltip, not the name, so VoiceOver read something
  like "x mark circle fill".
- **Fix:** each has a label in the app's language; the chevron also says whether it is expanded.
- **Status:** Fixed. `testIconOnlyButtonsHaveAnAccessibilityLabel` fails on a new one.

### MA4. Messages: conversations could be opened only with the mouse (Mac)

- **Where:** `MessagesWindow.swift:1178` (rows open on a tap gesture), `:685-710` (keys handled: Command-F,
  Shift-Command-U, Command-Delete, Escape).
- **Fix:** Up and Down open the conversation above or below, as in Mail, while no text is being typed.
- **Status:** Fixed. The rows are still not Tab stops; Up and Down are the keyboard way.

### MA5. Transfers: items could be chosen and opened only with the mouse (Mac)

- **Where:** `FileTransferWindow.swift:360-370` (Space and Escape only), `TransfersWindowView.swift:749`, `:807`
  (select on click, open on double-click; the item's buttons show on hover).
- **Fix:** the arrow keys move the selection through the items shown (with the filter applied) and Return opens the
  selected item. Space still previews it.
- **Status:** Fixed.

### MA6. An empty checkbox's outline was nearly invisible (Mac)

- **Where:** `FolderWindows.swift:551-568` (`BrandCheckboxStyle`: the folder sheet, the code model's terms).
- **What:** off, the box is only its outline, drawn in `ol`: 1.29:1 on white in light, 1.41:1 in dark. Controls need
  3:1. Its value was a hard-coded "on" or "off".
- **Evidence:** contrast computed from the `BrandPalette` tokens; `mac-controls-*` screenshots.
- **Fix:** the empty box's outline uses `on2` (7.8:1 light, 7.7:1 dark); the value is localised and the box reads as
  selected when ticked.
- **Status:** Fixed.

### ML2. Status lines were English in Russian (Mac)

- **Where:** `Pairing.swift` (call, ping, clipboard and file statuses, about 45 lines from `:1415` to `:4074`) and
  `QuickActions.swift:52-165`, shown in the menu bar panel, the Send sheet, the Tray and the Transfers window's live card.
- **What:** "Ping delivered", "Transfer cancelled", "Android is not connected" and the rest were plain literals, so
  the panel mixed Russian and English.
- **Fix:** `StatusText` (new, `StatusText.swift`) turns each line into the app's language where it is shown: 48 exact
  lines and 10 patterns ("Saved %1$@ to %2$@", "Sending %@…"), in both tables. The English stays the value inside
  because `TransfersModel` reads words such as "cancelled" from it to choose a chip and a reason.
- **Status:** Fixed. The progress detail inside "Receiving x: 42% · 12 MB / 40 MB · …" (`Pairing.swift:7134`, `:7473`)
  stayed English at first; the follow-up builds it in the app's language with `TransfersText.progressDetail`
  ("42 % · 12 МБ / 30 МБ · 3 МБ/с · Осталось 2 мин"), tested by `testTransferProgressShowsInRussian`.

### ML3. Text hard-coded in views (Mac)

- **Where:** the call card ("Use the phone to control this call." and the hide tooltip), the File transfers button
  (`MenuBarPanelSurface.swift:28`), the File drop window's title and drop area (`FileDropWindow.swift:9`, `:73`), the
  Export diagnostics and receive-folder panels (`Pairing.swift:2450`, `BridgeySettings.swift:548-549`), and the On/Off
  states of MA1 and MA2.
- **Fix:** all go through `L10n` with English and Russian entries.
- **Status:** Fixed. `testViewsHaveNoHardCodedText` fails on a new literal in a view call.

### ML4. Plurals (Mac)

- **Where:** `PhoneFilesViews.swift:1028-1031`, `PhoneFilesText.swift:190`, `SettingsSyncViews.swift:42`,
  `SettingsWindow.swift:1552-1554`; `Localization.swift`.
- **What:** English had no plural table, so "1 folders, 1 files", "1 of 1 files" and "1 items" showed. Russian lines
  with a number inside a sentence took the wrong form ("3 из 21 настроек", "Ещё 5 нажатия"). The existing Russian
  plural entries were picked by `Locale.current`, so they used English rules whenever the app's language and the
  region's language differed.
- **Fix:** `en.lproj/Localizable.stringsdict` (new) has the same 12 keys as Russian's, with five keys added to both
  (`phonefiles.counts`, `phonefiles.shown`, `phonefiles.progress.files`, `sync.choose.count`, `developer.tapsLeft`).
  `L10n.plural` formats with the rule of the language the strings are in. Most other Russian counts are written as
  "Файлов: 5", which needs no plural forms, and stay.
- **Status:** Fixed. `testRussianPluralsUseOneFewAndMany` checks 1, 3, 5, 11, 21 and 22.

### AA2. Device chips read the device name twice (Android)

- **Where:** `ui/SettingsCards.kt:405-428` (`DeviceChipView`: description `:419-420`, label `:426`). Seen in the Beta 11
  emulator smoke on Settings > Sharing > Clipboard.
- **What:** the merged node read "Rahul's Personal Mac, Clipboard, Rahul's Personal Mac".
- **Fix:** the visible label is cleared from the semantics; the chip reads the name, the feature and whether it is on.
- **Status:** Fixed. The read-twice check in `AccessibilityChecksTest` covers it.

### AA3. Other things read twice (Android)

- **Where:** `ui/HomeScreen.kt:219-273` (rings), `ui/DeviceScreen.kt:300-318` (battery), `ui/SettingsScreen.kt:338-357`
  (search), `ui/MacScreenScreen.kt:360-382` and `ui/RemoteScreen.kt:410-430` (key chips).
- **What:** "Work MacBook, Same Wi-Fi, Work MacBook, Same Wi-Fi"; "Battery 76%, charging, 76%"; "Search settings, Search
  settings". The check counted 75 such nodes on the base tree.
- **Fix:** the visible duplicate is cleared from the semantics.
- **Status:** Fixed.

### AA4. Text was cut at 200% (Android)

- **Where:** fixed heights in `ui/Components.kt` (pill buttons `:352`, `:416`, `:441`, status and route pills `:453`,
  `:481`, page bar `:529`), `ui/HomeScreen.kt` (app bar `:185`, ring strip `:208`, picker `:349`, composer `:412`),
  `ui/Stream.kt:495`, `ui/DeviceScreen.kt:337`, `:446`, `ui/RemoteScreen.kt:208`, `ui/AgentScreens.kt:247`,
  `ui/SettingsScreen.kt:903`, `ui/SetupQuestionScreens.kt:163-178`, `ui/MacScreenScreen.kt:112`,
  `ui/search/SettingsSearchScreen.kt:165-169`.
- **What:** in Russian at 200%, "от Round Robin" was cut, the ring statuses were squashed to 2 px (the status was lost),
  activity details and tabs ("Активнос", "Разрешен", "Сс…") were cut. The check counted 49 cut texts.
- **Fix:** heights are minimums. From 130% text (`largeText()`), titles and buttons wrap to two or three lines, rings
  widen to 128 dp, quick actions become a 2 by 2 grid, the channel picker stacks and tab labels hyphenate.
- **Status:** Fixed.

### AA5. Setup's main button lost its label at 200% (Android)

- **Where:** `ui/SetupQuestionScreens.kt` footers `:276-290`, `:387-396`, `:410-418`, `:453-459`, `:644-648`.
- **What:** in Russian at 200%, "Продолжить" measured 0 px wide and "Готово" became "Гот…".
- **Fix:** a `ButtonRow` (in `Components.kt`) moves buttons to a second line instead of squeezing them.
- **Status:** Fixed.

### AA6. The composer's Attach button was too small at 200% (Android)

- **Where:** `ui/HomeScreen.kt:338-405`.
- **Evidence:** ATF `TouchTargetSizeCheck`: 38 dp wide.
- **Fix:** the Send button no longer takes all the room; with large text it becomes a round icon button.
- **Status:** Fixed.

### AL3. Dialogs, notifications and window titles were English (Android)

- **Where:** `UpdatesUi.kt:74-107` (update and install-permission dialogs), `AppUpdater.kt:632-650`,
  `ReceivedFileNotifier.kt:36-92`, `RemoteCallRequest.kt:59-114`, `BridgeyConnectionService.kt:29-59`, `:299`,
  `:351-357` (channels and texts), `SessionRegistry.kt:258-274`, `ClipboardTileService.kt:31`,
  `control/BridgeyControlService.kt:369`, `:373`, `:465` (window titles TalkBack announces), `MainActivity.kt:586-616`
  (diagnostics export, the second-profile screen).
- **Fix:** all in the tables; `connectionStatus` takes a string lookup.
- **Status:** Fixed.

### AL4. Two actions had one Russian name (Android)

- **Where:** `res/values-ru/strings_display.xml:7`.
- **What:** "See screen" and "Share screen" were both "Показать экран" on the device page.
- **Fix:** "See screen" is "Смотреть экран".
- **Status:** Fixed.

### AL5. Plurals (Android)

- **Where:** `settings_notification_apps_count`, `attach_browsed_count` in `res/values/strings.xml`.
- **What:** plain strings: Russian "из 1 приложений", "из 21 приложений"; English "1 items".
- **Fix:** `<plurals>` with Russian one, few, many and other, English one and other.
- **Status:** Fixed.

## Low

### MA7. Sheets with only a Done button did not close with Escape (Mac)

- **Where:** `LicenceSheet` (`CodeModelViews.swift:653`), the Settings sync choices (`SettingsSyncViews.swift:66-78`).
- **Fix:** Escape closes them as Done does (`onExitCommand`). Return already pressed Done.
- **Status:** Fixed.

### MA8. Smaller fixes (Mac)

- The tailnet address field was named only by its placeholder ("work or 100.64.0.10"): it is now "Pair by tailnet name
  or address" (`SettingsWindow.swift:1187`).
- The Messages search sections are headings now, so VoiceOver can jump between them (`MessagesWindow.swift:1219`).
- The route symbol beside "Same Wi-Fi" in the menu bar panel's device chips is hidden from VoiceOver, which read it as
  well as the words (`StreamPanel.swift:531-535`).
- **Status:** Fixed.

### ML1. Messages search used small tracked capitals (Mac)

- **Where:** `MessagesWindow.swift:1219-1226` ("CONVERSATIONS", "MESSAGES").
- **Fix:** sentence case, untracked, 12 pt semibold, as the activity stream's day headings and the Settings cards.
- **Status:** Fixed (`mac-messages-search-*`).

### ML5. Russian did not fit, and a device name was cut in both languages (Mac)

- **Where:** the Settings sidebar ("Конфиденциальнос…", `SettingsWindow.swift:650`), the per-device screen menus
  ("По умолчанию (Разрешать без в…", `SettingsWindow.swift:857`), the menu bar panel's hint and status line
  (`StreamPanel.swift:1338`), and the panel's device chips ("OnePlu…" in English too, `StreamPanel.swift:509`).
- **Fix:** sidebar and chip names shrink to 80% before they are cut; a menu's chosen value keeps its width and the
  row title wraps; the panel's hint and status line wrap to a second line.
- **Status:** Fixed (`mac-settings-privacy-ru-*`, `mac-settings-control-more-ru-*`, `mac-panel-*`).

### ML6. Decimals in speeds used a full stop in Russian (Mac)

- **Where:** `SpeedTestView.swift:104` ("%.1f МБ/с"), `ConnectionHealth.swift:233` ("%.1f s").
- **Fix:** both format with the user's locale ("12,4 МБ/с"). Sizes and other speeds already used
  `ByteCountFormatter`, and dates and times the locale's formats.
- **Status:** Fixed.

### AA7. Touch targets under 48 dp (Android)

- **Where:** chips (`ui/SettingsCards.kt:405`, 40 dp), the search clear button (`ui/search/SettingsSearchScreen.kt:188`,
  40 dp), the launcher chip (`ui/MacActionsUi.kt:190-200`, 40 dp).
- **Fix:** `minimumInteractiveComponentSize()`; the clear button is 48 dp.
- **Status:** Fixed.

### AA8. Repeated names on one page (Android)

- **Where:** `ui/SettingsCards.kt:330-352` (More options), `ui/SetupQuestionScreens.kt:722`, `:745`, `:761`.
- **Evidence:** ATF `DuplicateSpeakableText`: "More options" three times on a page, "Change in Settings" seven times on
  setup's summary.
- **Fix:** "More options for %1$s", "Change %1$s in Settings".
- **Status:** Fixed.

### AL6. Speeds and percentages in the locale (Android)

- **Where:** `ui/DeviceScreen.kt:456-458` ("2.1 Mb/s"), `:317` ("76%").
- **Fix:** `NumberFormat` with the app's locale; "%1$s Мбит/с"; the percent format gives "76 %" in Russian.
- **Status:** Fixed.

### AL7. The media card's default line was English (Android)

- **Where:** `QuickActions.kt:40`.
- **Fix:** empty by default; the card shows `media_choose_player`.
- **Status:** Fixed.

### AL8. Setup questions had an uppercase eyebrow (Android)

- **Where:** `ui/SetupQuestionScreens.kt:232-243` (eyebrow at `:239`), and the summary labels at `:700-702`.
- **What:** "NOTIFICATIONS" in small capitals above every setup heading; the summary used tracked capitals
  ("ВКЛЮЧЕНО").
- **Fix:** the eyebrow is gone; the summary uses the sentence-case list style. No other uppercase or tracked text is
  left in the Android UI.
- **Status:** Fixed.

### MA9. The Mac app has no larger text (Mac)

- **Where:** `BrandTheme.swift` (`BrandFont`: fixed sizes, mostly 11 to 15 pt).
- **What:** macOS has no app-wide Dynamic Type, and its Text size setting reaches only apps that adopt it. Bridgey has
  no text size of its own, so people who need larger text rely on Zoom.
- **Status:** Won't do for 1.0. macOS has no system Dynamic Type for apps to follow. Bridgey follows the system's
  Reduce motion, and Zoom enlarges it as it does any app. A text size of its own would be a new setting and a new look
  to check in every window.

### ML7. The Siri phrases of the App Shortcuts are English only (Mac)

- **Where:** `BridgeyIntents.swift:212-215` (four `AppShortcut` phrases), `build-app.sh` (`--no-app-shortcuts-localization`).
- **What:** the actions' titles, descriptions, parameters and dialogs are keyed (`intent.*`, `focus.filter.*`) and were
  already in both tables; this review first counted them as English, which was wrong. `testEveryKeyTheCodeUsesExists`
  now checks those keys too. Only the spoken phrases ("Ring my phone with Bridgey") are English in every language.
- **Status:** Open. Localised phrases need an `AppShortcuts.xcstrings` catalogue, the metadata processor run without
  `--no-app-shortcuts-localization` (it then validates every phrase), and a check with Siri and Shortcuts on a Mac in
  Russian, which we do not run on the team's own Macs. That is more than a small build step.

### AA10. Text field borders were too faint (Android)

- **Where:** `ui/SetupQuestionScreens.kt:567-583` (setup, `outlineVariant`, 1.14:1); the Material default
  (`outline`, 1.4:1 in dark) on the device name, tailnet address, folder name, agent invite and reply fields; no
  edge at all on the pill fields (settings search, the device page's composer, the remote text and Mac screen keyboard
  fields) or `composerOutline` (1.29:1 in light).
- **What:** an unfocused field's edge needs 3:1 against what is behind it.
- **Fix:** `bridgeyTextFieldColors()` (in `Components.kt`) for every `OutlinedTextField` and `fieldBorderColor` for the
  pill fields, both the existing `onSurfaceVariant` token: 7.3:1 to 8.1:1 on the page, cards and composer in light and
  dark. Focused, the border stays primary. The home composer, which holds buttons and no field, is unchanged.
- **Status:** Fixed. `TextFieldContrastTest` checks the ratio in both themes (`followups/aa10-*`).

### AA13. Two Clear and two Allow buttons shared a name (Android)

- **Where:** Settings > Privacy (Activity and Logs), the Allow buttons on the calls and messages access rows, and the
  battery row's Allow.
- **What:** ATF warned; the row title before each gave the context only when read in order.
- **Fix:** `OutlinePillButton` and `TonalPillButton` take a `label` that TalkBack reads instead of the word on the
  button: "Clear activity", "Clear logs", "Allow background use" and "Allow %1$s" with the row's title (Russian
  "Разрешить: %1$s").
- **Status:** Fixed.

### AL10. Russian at 200% broke long words without a hyphen (Android)

- **What:** "Автоматическ/ий" on Settings > Sharing.
- **Fix:** every `BridgeyType` style and the default text style hyphenate when the app's language is Russian
  (`Hyphens.Auto`); English wraps as before.
- **Status:** Fixed. On the `bridgey-api36` emulator at 200%: "Автоматиче-ский" in Russian, English unchanged
  (`followups/android-emulator-sharing-*`). Robolectric has no hyphenation patterns, so `RussianHyphenationTest`
  checks the styles.

## Checked and found sound

- **MA10, AA11. Reduce motion.** Mac: every SwiftUI animation goes through `BrandMotion` with `brandReduceMotion`
  (the system setting or Bridgey's own), and the menu bar panel, code float, call card fade and the sharing pill's pulse
  check it too. Android: every animation goes through `LocalMotion` (`ui/motion/Motion.kt:147-151`), instant when the
  animator scale is 0 and a fade only with Bridgey's Reduce motion. Material's indeterminate progress bars keep moving,
  which is allowed for essential motion.
- **MA11, AA9. Contrast.** Every text token is 5.0:1 or better in light and dark on both apps (lowest: primary, good
  and warn on surface 4 in light, 5.01:1). Switches: the on track is 6.5:1 to 9.6:1 against the card, and the off
  thumb about 6:1 against its track, so the state is clear although the off track itself is 1.29:1. The outline token (`ol`,
  1.2:1 to 1.5:1) only edges controls that text, a thumb or a check mark already identify, except the checkbox (MA6) and
  the setup field (AA10). Dimmed controls are disabled, which is exempt.
- **MA12, AA12. Colour alone.** Connection rings differ in style (gradient, dashed, solid) and sit beside a status line,
  now kept at 200% on Android; chips add a check mark when on; the Transfers chips have words.
- **ML8, AL9. Keys and formats.** Before the fixes, English and Russian had the same keys in every table on both apps
  (Mac 1,937, 247 and 69; Android 1,935 plus one not translated) and the same format arguments. The Mac code used two
  keys neither table had (`action.on`, `action.off`, see MA2).
- **ML9, AL11. Copy.** English is British in both apps ("MIT License" is a name), and no table has an em dash. The Mac
  app has no eyebrows. Android's speed test and performance reports stay English on purpose, because they are
  reports for support.

## Automated checks added

| Check | App | What it fails on |
| --- | --- | --- |
| `LocalizationTests` (8 tests) | Mac | Keys or format arguments that differ between English and Russian in any table or the plural tables; a Russian plural rule without one, few, many and other; a key the code uses that a table lacks; wrong plural output (1, 3, 5, 11, 21, 22); status lines not shown in Russian; a literal in a view call (`Text("…")`, `.help("…")`, `.accessibilityLabel("…")`, panel titles); American spelling or a dash in the copy |
| `AccessibilityAuditTests` (4 tests) | Mac | The Settings window's six groups (More options open) and nine other surfaces in English and Russian, walked through the accessibility tree: a control with no name or an SF Symbol name; an icon-only `Button` without `.accessibilityLabel`; a new `.onTapGesture` not on the reviewed list |
| `AccessibilityL10nScreenshots` | Mac | Draws the review's surfaces in English and Russian, light and dark, when `BRIDGEY_SCREENSHOT_DIR` is set |
| `StringResourcesTest` (6 tests) | Android | English and Russian key sets, format arguments, plural forms (Russian one, few, many, other), em dashes, American spelling, and hard-coded copy in UI code (`Text("…")`, content descriptions, notifications and channels, toasts, snackbars, window titles) |
| `AccessibilityChecksTest` (14 tests) | Android | 14 screens (Settings and its six groups, Home, the device page's Activity and Permissions, setup, the Mac screen viewer), each in English, light, 100% text and in Russian, dark, 200% text: any ATF error, cut or ellipsised text, a switch, checkbox or radio button with no state, and anything read twice |

Two limits. SwiftUI builds its own accessibility nodes only once an assistive app such as VoiceOver connects, and
asking from outside the process needs the Accessibility permission, so the Mac walk reaches the AppKit-backed
controls (fields, text areas, scroll views) and the source checks cover the SwiftUI ones. Espresso's
`AccessibilityChecks` needs instrumented tests, which RR CI does not run, so ATF runs inside the Robolectric tests.

## Screenshots

In `outputs/bridgey/a11y-l10n/` in the PA workspace, `before/` (rr/main `a85698c6`) and `after/` (this branch):

- `mac/`: Messages search, the menu bar panel, the checkbox and switch, the Settings sidebar on Privacy and the
  Control group in full, each in English and Russian, light and dark (20 each).
- `android/`: the 14 checked screens in English, light, 100% and Russian, dark, 200%, plus setup's question, switches
  and summary in light and dark (34 before, 36 after).

## Tests and where they ran

- **Mac, personal Mac (macOS 27.2, Swift 6.4.2, debug):** the whole suite, 1,911 tests, 106 skipped, 0 failures. Four
  tests read files outside `macos/` that the first copy left out; they passed once those were copied.
- **Android, rr-dev-1:** the `rr-ci/android` lane's command (`lintDebug` and `testDebugUnitTest` for `:app` and
  `:core:discovery`, `assembleDebug`) with the Rust core skipped locally: 2,196 tests, 5 skipped, 0 failures, lint clean.
- **RR CI:** every lane on the PR (see the PR's checks).
- **Not run:** TalkBack speech, and VoiceOver on a real Mac. The Robolectric and in-process checks cover the semantics
  those would read, but not the speech itself. A real 200% font scale ran on the `bridgey-api36` emulator only for
  the follow-up's Settings > Sharing check.

## Follow-up

The second PR (`rr/a11y-followups`, from `rr/main` `395473d9`) fixed AA10, AA13, AL10 and the rest of ML2, corrected
ML7 and closed MA9 as won't do for 1.0, with the defaults the coordinator chose under the owner's standing rule.

- **Checks added:** `TextFieldContrastTest`, `RussianHyphenationTest` (Android); `testTransferProgressShowsInRussian`
  and App Intents keys in `testEveryKeyTheCodeUsesExists` (Mac).
- **Screenshots:** `outputs/bridgey/a11y-l10n/followups/` in the PA workspace: the setup, device composer, remote and
  Mac screen keyboard fields before and after in light and dark (Robolectric), and Settings > Sharing at 200% on the
  emulator in Russian before and after, and English after.
- **Emulator:** a stress build (its own app ID) on `bridgey-api36` with its app language set to Russian and font scale
  2.0; afterwards font scale went back to 1.0 and the build was removed.
- **Local runs:** the `rr-ci/android` lane's command on rr-dev-1, 2,199 tests, 5 skipped, 0 failures, lint clean (the
  two hyphenation tests first failed on test setup and pass now); the changed Mac tests on the personal Mac with
  warnings as errors, 0 failures. RR CI ran every lane on the PR.

## Needs Rahul

Nothing open.
