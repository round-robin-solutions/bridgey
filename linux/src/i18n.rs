//! English (British) and Russian, chosen from the desktop's language (LANGUAGE, LC_ALL, LC_MESSAGES, LANG) or
//! BRIDGEY_LANG. Strings live in one table, so the AppImage needs no gettext catalogue; terms follow the Mac's
//! Russian strings (macos/Resources/ru.lproj).

use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Lang {
    En,
    Ru,
}

static LANG: OnceLock<Lang> = OnceLock::new();

pub fn pick(vars: &[Option<String>]) -> Lang {
    for v in vars.iter().flatten() {
        let first = v.split(':').next().unwrap_or("").to_ascii_lowercase();
        if first.is_empty() || first == "c" || first == "posix" || first.starts_with("c.") {
            continue;
        }
        return if first.starts_with("ru") { Lang::Ru } else { Lang::En };
    }
    Lang::En
}

pub fn init() {
    let get = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    let lang = pick(&[get("BRIDGEY_LANG"), get("LANGUAGE"), get("LC_ALL"), get("LC_MESSAGES"), get("LANG")]);
    let _ = LANG.set(lang);
}

pub fn lang() -> Lang {
    *LANG.get().unwrap_or(&Lang::En)
}

pub fn lang_code() -> &'static str {
    match lang() {
        Lang::En => "en",
        Lang::Ru => "ru",
    }
}

fn lookup(key: &str, lang: Lang) -> Option<&'static str> {
    STRINGS.iter().find(|(k, ..)| *k == key).map(|(_, en, ru)| if lang == Lang::Ru { *ru } else { *en })
}

/// The string for `key` in the app's language. A missing key shows the key, so a test catches it.
pub fn t(key: &str) -> &'static str {
    lookup(key, lang()).unwrap_or_else(|| Box::leak(key.to_string().into_boxed_str()))
}

/// `t` with {0}, {1}… filled in.
pub fn tf(key: &str, args: &[&str]) -> String {
    let mut s = t(key).to_string();
    for (i, a) in args.iter().enumerate() {
        s = s.replace(&format!("{{{i}}}"), a);
    }
    s
}

/// (key, English, Russian).
pub const STRINGS: &[(&str, &str, &str)] = &[
    ("about.comments", "Your phone and this computer, together: clipboard, files and notifications. Built on Bridgey by Semyon Mikhailov, including upstream up to {0}.", "Телефон и этот компьютер вместе: буфер обмена, файлы и уведомления. Основано на Bridgey Семёна Михайлова, включая версии до {0}."),
    ("about.upstream", "Bridgey", "Bridgey"),
    ("activity.clear", "Clear activity", "Очистить активность"),
    ("activity.clipboard_auto_to", "Clipboard to {0}, automatically", "Буфер обмена на {0}, автоматически"),
    ("activity.clipboard_from", "Clipboard from {0}", "Буфер обмена с {0}"),
    ("activity.clipboard_to", "Clipboard to {0}", "Буфер обмена на {0}"),
    ("activity.declined", "Declined there", "Отклонено там"),
    ("activity.file_from", "File from {0}", "Файл с {0}"),
    ("activity.file_to", "File to {0}", "Файл на {0}"),
    ("activity.link_from", "Link from {0}", "Ссылка с {0}"),
    ("activity.link_to", "Link to {0}", "Ссылка на {0}"),
    ("activity.links_off", "Links are off there", "Там выключены ссылки"),
    ("activity.no_answer", "No answer", "Нет ответа"),
    ("activity.not_delivered", "Not delivered", "Не доставлено"),
    ("activity.ping_from", "Ping from {0}", "Пинг с {0}"),
    ("activity.ping_to", "Ping to {0}", "Пинг на {0}"),
    ("activity.progress", "{0} of {1}", "{0} из {1}"),
    ("activity.received", "Received", "Получено"),
    ("activity.receiving", "Receiving", "Получение"),
    ("activity.saved", "Saved", "Сохранено"),
    ("activity.sending", "Sending", "Отправка"),
    ("activity.sent", "Sent", "Отправлено"),
    ("activity.title", "Activity", "Активность"),
    ("channel.beta", "Beta", "Beta"),
    ("channel.nightly", "Nightly", "Nightly"),
    ("channel.stable", "Stable", "Stable"),
    ("clipboard.copied_from", "Copied from {0}", "Скопировано с {0}"),
    ("clipboard.copy_here", "Copy", "Скопировать"),
    ("clipboard.file_name", "Clipboard", "Буфер обмена"),
    ("clipboard.image_name", "Copied image", "Скопированное изображение"),
    ("clipboard.mode.datacontrol", "Works in the background.", "Работает в фоне."),
    ("clipboard.mode.foreground", "Works while Bridgey is in front. From the background, use Send copied item, and Copy on the banner for text from your phone.", "Работает, пока Bridgey на переднем плане. Из фона используйте «Отправить скопированное», а для текста с телефона нажмите «Скопировать» в уведомлении."),
    ("clipboard.mode.x11", "Works in the background.", "Работает в фоне."),
    ("clipboard.mode.xwayland", "Works in the background through XWayland, which GNOME keeps in step with the clipboard.", "Работает в фоне через XWayland: GNOME синхронизирует его с буфером обмена."),
    ("clipboard.waiting", "Text from {0}", "Текст с {0}"),
    ("code.copied", "Code {0} copied", "Код {0} скопирован"),
    ("common.cancel", "Cancel", "Отмена"),
    ("common.dismiss", "Dismiss", "Скрыть"),
    ("common.done", "Done", "Готово"),
    ("common.not_now", "Not now", "Не сейчас"),
    ("connect.connecting", "Connecting to Round Robin's service…", "Подключение к сервису Round Robin…"),
    ("connect.disabled", "Devices on your private networks can reach this computer.", "Устройства в ваших частных сетях могут подключаться к этому компьютеру."),
    ("connect.failed", "Connect away from home couldn't start. {0}", "Не удалось включить связь вне дома. {0}"),
    ("connect.off", "Off. Devices connect only on the same network.", "Выключено. Устройства подключаются только в одной сети."),
    ("connect.online", "Online. Your devices can reach this computer from any network.", "В сети. Ваши устройства подключаются к этому компьютеру из любой сети."),
    ("connect.unavailable", "Not available on this computer right now.", "Сейчас недоступно на этом компьютере."),
    ("connect.unreachable", "Round Robin's service can't be reached. Your local and private networks still work.", "Сервис Round Robin недоступен. Локальная и частные сети работают."),
    ("device.away_chip", "Away", "Вне дома"),
    ("device.away_tip", "Connects from other networks too", "Подключается и из других сетей"),
    ("device.battery", "Battery {0}%", "Батарея {0}%"),
    ("device.battery_charging", "Battery {0}%, charging", "Батарея {0}%, заряжается"),
    ("device.connected", "Connected", "Подключено"),
    ("device.forget", "Forget", "Забыть"),
    ("device.more", "More", "Ещё"),
    ("device.more_for", "More for {0}", "Ещё для {0}"),
    ("device.not_connected", "Not connected", "Не подключено"),
    ("device.ping", "Ping", "Пинг"),
    ("device.ring", "Ring", "Позвонить"),
    ("device.ringing", "Ringing", "Звонит"),
    ("device.send_clipboard", "Send copied item", "Отправить скопированное"),
    ("device.send_files", "Send files", "Отправить файлы"),
    ("device.settings", "Device settings", "Настройки устройства"),
    ("device.stop_ring", "Stop ringing", "Остановить звонок"),
    ("device.unnamed", "A device", "Устройство"),
    ("error.start", "Bridgey couldn't start", "Не удалось запустить Bridgey"),
    ("error.start_detail", "{0}. If another Bridgey is running on this computer, quit it and open this one again.", "{0}. Если на этом компьютере уже запущен другой Bridgey, закройте его и откройте этот снова."),
    ("file.cancelled", "Cancelled", "Отменено"),
    ("file.cancelled_remote", "Cancelled there", "Отменено там"),
    ("file.changed", "The file changed while it was sent", "Файл изменился во время отправки"),
    ("file.failed", "Not sent", "Не отправлено"),
    ("file.interrupted", "Interrupted. It continues when you send it again.", "Прервано. Продолжится, когда вы отправите его снова."),
    ("file.not_accepted", "Not accepted there", "Не принято там"),
    ("file.open", "Open", "Открыть"),
    ("file.received_from", "File from {0}", "Файл с {0}"),
    ("file.rejected", "Files are off there", "Там выключены файлы"),
    ("file.show_in_folder", "Show in folder", "Показать в папке"),
    ("file.storage", "Not enough space", "Не хватает места"),
    ("file.unreadable", "The file can't be read", "Не удаётся прочитать файл"),
    ("forget.body", "This computer stops trusting it. To use it again, pair again and compare the code.", "Этот компьютер перестанет ему доверять. Чтобы снова пользоваться им, свяжите устройства и ещё раз сравните код."),
    ("forget.title", "Forget {0}?", "Забыть {0}?"),
    ("home.devices", "Devices", "Устройства"),
    ("home.empty.body", "Open Bridgey on your phone, on the same Wi-Fi as this computer.", "Откройте Bridgey на телефоне в той же сети Wi-Fi, что и этот компьютер."),
    ("home.empty.title", "Pair your phone", "Свяжите телефон"),
    ("link.open", "Open", "Открыть"),
    ("link.sent", "{0} sent a link: {1}", "{0} отправил ссылку: {1}"),
    ("menu.about", "About Bridgey", "О Bridgey"),
    ("menu.allow_pairing", "Allow pairing", "Разрешить сопряжение"),
    ("menu.main", "Main menu", "Главное меню"),
    ("menu.quit", "Quit", "Выйти"),
    ("menu.send_clipboard", "Send copied item", "Отправить скопированное"),
    ("menu.send_files", "Send files…", "Отправить файлы…"),
    ("menu.settings", "Settings", "Настройки"),
    ("nav.home", "Home", "Главная"),
    ("nav.notifications", "Notifications", "Уведомления"),
    ("notice.copy_code", "Copy code {0}", "Скопировать код {0}"),
    ("notice.dismiss", "Dismiss", "Скрыть"),
    ("notice.replied", "Replied to {0}", "Ответ отправлен: {0}"),
    ("notice.reply_placeholder", "Reply", "Ответ"),
    ("notice.reply_to", "Reply to {0}", "Ответить: {0}"),
    ("notice.send_reply", "Send", "Отправить"),
    ("notices.clear", "Clear all", "Очистить всё"),
    ("notices.empty.body", "Your phone's notifications show here and as desktop notifications.", "Уведомления телефона появляются здесь и на рабочем столе."),
    ("notices.empty.title", "No notifications", "Нет уведомлений"),
    ("pair.address", "Address, such as 192.168.1.20", "Адрес, например 192.168.1.20"),
    ("pair.allow", "Allow", "Разрешить"),
    ("pair.allowed_body", "Other devices can pair with this computer for two minutes.", "Другие устройства могут связаться с этим компьютером в течение двух минут."),
    ("pair.allowed_title", "Pairing allowed", "Сопряжение разрешено"),
    ("pair.bad_address", "That isn't an address Bridgey can use.", "Bridgey не может использовать этот адрес."),
    ("pair.by_address", "Pair by address", "Сопряжение по адресу"),
    ("pair.by_address_detail", "For a device on another network, such as Tailscale. Choose Allow pairing there first.", "Для устройства в другой сети, например Tailscale. Сначала нажмите там «Разрешить сопряжение»."),
    ("pair.code_label", "Code {0}", "Код {0}"),
    ("pair.compare", "Check that {0} shows this code", "Сверьте код с {0}"),
    ("pair.done", "Paired with {0}", "Связано с {0}"),
    ("pair.failed", "Pairing didn't finish", "Сопряжение не завершено"),
    ("pair.failed.busy", "That device is pairing with another device. Try again in a moment.", "Это устройство сейчас сопрягается с другим. Попробуйте чуть позже."),
    ("pair.failed.cancelled_there", "Pairing was cancelled on the other device.", "Сопряжение отменено на другом устройстве."),
    ("pair.failed.code", "The codes didn't match, so nothing was paired.", "Коды не совпали, поэтому ничего не сопряжено."),
    ("pair.failed.identity", "That device's key changed. Forget it on both devices, then pair again.", "Ключ этого устройства изменился. Забудьте его на обоих устройствах и выполните сопряжение заново."),
    ("pair.failed.not_allowed", "The other device didn't allow pairing in time. Try again and allow it there.", "На другом устройстве не разрешили сопряжение вовремя. Попробуйте снова и разрешите его там."),
    ("pair.failed.other", "Pairing didn't finish. Try again.", "Сопряжение не завершено. Попробуйте снова."),
    ("pair.failed.rate", "Too many tries. Wait a minute, then try again.", "Слишком много попыток. Подождите минуту и попробуйте снова."),
    ("pair.failed.timeout", "The code wasn't confirmed in time.", "Код не подтвердили вовремя."),
    ("pair.failed.unreachable", "Bridgey couldn't reach that device. Check it's on the same network with Bridgey open.", "Не удалось связаться с устройством. Проверьте, что оно в той же сети и Bridgey открыт."),
    ("pair.failed.update", "That device needs a newer Bridgey to pair. Update it, then try again.", "Для сопряжения на том устройстве нужна более новая версия Bridgey. Обновите её и попробуйте снова."),
    ("pair.intro", "Open Bridgey on the other device. Devices on this network show here.", "Откройте Bridgey на другом устройстве. Устройства в этой сети появятся здесь."),
    ("pair.looking", "Looking for devices…", "Поиск устройств…"),
    ("pair.match", "Codes match", "Коды совпадают"),
    ("pair.nearby", "Nearby", "Рядом"),
    ("pair.no_match", "Don't match", "Не совпадают"),
    ("pair.pair", "Pair", "Связать"),
    ("pair.pair_with", "Pair with {0}", "Связать с {0}"),
    ("pair.request", "{0} wants to pair with this computer.", "{0} хочет связаться с этим компьютером."),
    ("pair.title", "Pair a new device", "Связать новое устройство"),
    ("pair.try_again", "Try again", "Повторить"),
    ("pair.waiting", "Open Bridgey on {0} and choose Allow pairing", "Откройте Bridgey на {0} и нажмите «Разрешить сопряжение»"),
    ("pair.waiting_detail", "Bridgey tries again every few seconds for two minutes.", "Bridgey повторяет попытку каждые несколько секунд в течение двух минут."),
    ("pair.waiting_label", "Waiting", "Ожидание"),
    ("ring.stop", "Stop", "Остановить"),
    ("ring.title", "{0} is ringing this computer", "{0} звонит на этот компьютер"),
    ("send.choose_device", "Send to which device?", "На какое устройство отправить?"),
    ("send.choose_files", "Send files", "Отправить файлы"),
    ("send.failed", "Couldn't send. {0}", "Не удалось отправить. {0}"),
    ("send.file_count", "Files: {0}", "Файлов: {0}"),
    ("send.label", "Text to send", "Текст для отправки"),
    ("send.no_device", "No device is connected. Open Bridgey on your phone.", "Нет подключённых устройств. Откройте Bridgey на телефоне."),
    ("send.no_folders", "Folders can't be sent yet.", "Папки пока нельзя отправлять."),
    ("send.placeholder", "Type or paste to send", "Введите или вставьте текст"),
    ("send.send", "Send", "Отправить"),
    ("send.send_link", "Send link", "Отправить ссылку"),
    ("send.to", "Send to", "Кому"),
    ("sendto.script_name", "Send to Bridgey", "Отправить в Bridgey"),
    ("settings.activity", "Activity", "Активность"),
    ("settings.app", "App", "Приложение"),
    ("settings.app_menu", "Show Bridgey in the app menu", "Показывать Bridgey в меню приложений"),
    ("settings.app_menu_detail", "Points at this AppImage wherever you keep it.", "Указывает на этот AppImage, где бы он ни лежал."),
    ("settings.appearance", "Appearance", "Оформление"),
    ("settings.auto_clipboard", "Automatic clipboard", "Автоматический буфер обмена"),
    ("settings.auto_clipboard_detail", "Copy here, paste on your phone. Passwords never go.", "Скопируйте здесь, вставьте на телефоне. Пароли не передаются."),
    ("settings.auto_update", "Check when Bridgey opens", "Проверять при запуске Bridgey"),
    ("settings.auto_update_detail", "At most every six hours. Installing always asks first.", "Не чаще раза в шесть часов. Перед установкой всегда спрашивает."),
    ("settings.autostart", "Start at sign-in", "Запускать при входе"),
    ("settings.autostart_detail", "Starts in the background, without the window.", "Запускается в фоне, без окна."),
    ("settings.away", "Connect away from home", "Связь вне дома"),
    ("settings.away_detail", "Your devices reach this computer from other networks through Round Robin's encrypted relay.", "Ваши устройства подключаются к этому компьютеру из других сетей через зашифрованный ретранслятор Round Robin."),
    ("settings.background_clipboard", "Work in the background", "Работать в фоне"),
    ("settings.background_clipboard_detail", "Follow copies and set the clipboard without Bridgey's window in front, where the desktop allows it.", "Следить за копированием и менять буфер обмена без окна Bridgey, если это позволяет рабочий стол."),
    ("settings.banners", "Desktop notifications", "Уведомления на рабочем столе"),
    ("settings.banners_detail", "Off: they show only in Bridgey.", "Если выключено, они видны только в Bridgey."),
    ("settings.battery", "Battery", "Батарея"),
    ("settings.battery_detail", "This computer's battery on your devices, and theirs here.", "Батарея этого компьютера на ваших устройствах, а их здесь."),
    ("settings.change", "Change…", "Изменить…"),
    ("settings.change_folder", "Change the folder for received files", "Изменить папку для полученных файлов"),
    ("settings.channel", "Update channel", "Канал обновлений"),
    ("settings.clear", "Clear", "Очистить"),
    ("settings.clear_activity", "Clear activity and notifications", "Очистить активность и уведомления"),
    ("settings.cleared", "Cleared", "Очищено"),
    ("settings.clipboard", "Clipboard", "Буфер обмена"),
    ("settings.clipboard_detail", "Text both ways with your devices. Copied images and files go as files.", "Текст в обе стороны. Скопированные изображения и файлы отправляются как файлы."),
    ("settings.clipboard_here", "On this desktop", "На этом рабочем столе"),
    ("settings.codes", "Codes from messages", "Коды из сообщений"),
    ("settings.codes_detail", "One-time codes from texts show with Copy code. They're found on this computer and go nowhere else.", "Одноразовые коды из SMS показываются с кнопкой «Скопировать код». Они находятся на этом компьютере и никуда не отправляются."),
    ("settings.codes_email", "Also read codes in email", "Также читать коды из почты"),
    ("settings.control", "Control", "Управление"),
    ("settings.copy_codes", "Copy codes automatically", "Копировать коды автоматически"),
    ("settings.data", "Your data", "Ваши данные"),
    ("settings.data_detail", "Pairing keys and settings stay on this computer, readable only by you.", "Ключи сопряжения и настройки хранятся на этом компьютере и доступны только вам."),
    ("settings.data_folder", "Folder", "Папка"),
    ("settings.device_features", "Battery, Find device and Ping", "Батарея, поиск устройства и пинг"),
    ("settings.devices", "Devices", "Устройства"),
    ("settings.file_manager", "Send to Bridgey in Files", "«Отправить в Bridgey» в Файлах"),
    ("settings.file_manager_detail", "Right-click files in Files, Nemo or Dolphin to send them.", "Нажмите правой кнопкой на файлы в Файлах, Nemo или Dolphin, чтобы отправить их."),
    ("settings.file_notifications", "Notify when a file arrives", "Сообщать о полученных файлах"),
    ("settings.files", "Files", "Файлы"),
    ("settings.files_detail", "Files both ways. Interrupted files continue where they stopped.", "Файлы в обе стороны. Прерванные передачи продолжаются с того же места."),
    ("settings.find", "Find device", "Поиск устройства"),
    ("settings.find_detail", "Your devices can ring this computer, and it can ring them.", "Ваши устройства могут позвонить на этот компьютер, а он на них."),
    ("settings.general", "General", "Основные"),
    ("settings.history", "Keep history", "Хранить историю"),
    ("settings.history_detail", "Seven days, at most 200. Codes are never kept.", "Семь дней, не больше 200. Коды не хранятся."),
    ("settings.keep_running", "Keep running when the window closes", "Работать после закрытия окна"),
    ("settings.keep_running_detail", "Open Bridgey again from your apps or the tray.", "Откройте Bridgey снова из приложений или из трея."),
    ("settings.links", "Links", "Ссылки"),
    ("settings.links_detail", "Send the page you're on, or a link, either way.", "Отправляйте открытую страницу или ссылку в обе стороны."),
    ("settings.media", "Media controls", "Управление медиа"),
    ("settings.media_detail", "The phone's media buttons control what plays here.", "Медиакнопки телефона управляют тем, что играет здесь."),
    ("settings.muted", "Apps without banners", "Приложения без уведомлений"),
    ("settings.muted_detail", "Their notifications show only in Bridgey.", "Их уведомления видны только в Bridgey."),
    ("settings.name", "Name", "Имя"),
    ("settings.no_devices", "No devices paired yet", "Пока нет связанных устройств"),
    ("settings.notifications", "Notifications", "Уведомления"),
    ("settings.notifications_detail", "Your phone's notifications on this computer.", "Уведомления телефона на этом компьютере."),
    ("settings.open_links", "Open links right away", "Сразу открывать ссылки"),
    ("settings.open_links_detail", "Off: links wait on Home for Open.", "Если выключено, ссылки ждут на главной."),
    ("settings.pair_detail", "Your phone, a Mac or another computer.", "Телефон, Mac или другой компьютер."),
    ("settings.paired", "Paired devices", "Связанные устройства"),
    ("settings.paired_detail", "Each device has its own switches.", "У каждого устройства свои переключатели."),
    ("settings.phone", "Phone", "Телефон"),
    ("settings.ping", "Ping", "Пинг"),
    ("settings.presence", "Share when I'm using this computer", "Сообщать, когда я пользуюсь этим компьютером"),
    ("settings.presence_detail", "Your phone sends alerts to the device you're using. Only whether there was input, never what.", "Телефон отправляет уведомления туда, где вы сейчас. Передаётся только факт ввода, но не что именно."),
    ("settings.previews", "Show previews in activity", "Показывать превью в активности"),
    ("settings.previews_detail", "Off: only that something was sent.", "Если выключено, видно только сам факт отправки."),
    ("settings.privacy", "Privacy", "Конфиденциальность"),
    ("settings.receive_folder", "Save received files in", "Сохранять полученные файлы в"),
    ("settings.reduce_motion", "Reduce motion", "Меньше движения"),
    ("settings.reduce_motion_detail", "No fades or slides in Bridgey.", "Без плавных переходов в Bridgey."),
    ("settings.sharing", "Sharing", "Обмен"),
    ("settings.status", "Status", "Состояние"),
    ("settings.this_computer", "This computer", "Этот компьютер"),
    ("settings.title", "Settings", "Настройки"),
    ("settings.tray", "Tray icon", "Значок в трее"),
    ("settings.tray_missing", "This desktop has no tray. Bridgey keeps running in the background; open it from your apps.", "На этом рабочем столе нет трея. Bridgey работает в фоне, открывайте его из приложений."),
    ("settings.tray_shown", "Shown", "Показан"),
    ("settings.unmute", "Show banners from {0}", "Показывать уведомления {0}"),
    ("settings.updates", "Updates", "Обновления"),
    ("settings.version", "Version", "Версия"),
    ("status.connected_count", "Connected to {0} devices", "Подключено устройств: {0}"),
    ("status.connected_to", "Connected to {0}", "Подключено к {0}"),
    ("status.none_connected", "No devices connected", "Нет подключённых устройств"),
    ("status.none_paired", "No devices paired", "Нет связанных устройств"),
    ("theme.dark", "Dark", "Тёмное"),
    ("theme.light", "Light", "Светлое"),
    ("theme.system", "System", "Как в системе"),
    ("tray.allow_pairing", "Allow pairing", "Разрешить сопряжение"),
    ("tray.open", "Open Bridgey", "Открыть Bridgey"),
    ("tray.pair", "Pair a new device…", "Связать новое устройство…"),
    ("tray.quit", "Quit", "Выйти"),
    ("tray.send_clipboard", "Send copied item", "Отправить скопированное"),
    ("tray.send_files", "Send files…", "Отправить файлы…"),
    ("tray.settings", "Settings", "Настройки"),
    ("update.check", "Check now", "Проверить"),
    ("update.checking", "Checking…", "Проверка…"),
    ("update.confirm_body", "Bridgey downloads it ({0}), checks its signature and restarts.", "Bridgey загрузит обновление ({0}), проверит подпись и перезапустится."),
    ("update.confirm_title", "Install Bridgey {0}?", "Установить Bridgey {0}?"),
    ("update.current", "{0}", "{0}"),
    ("update.downloading", "Downloading the update: {0} of {1}", "Загрузка обновления: {0} из {1}"),
    ("update.failed", "Couldn't check for updates. {0}", "Не удалось проверить обновления. {0}"),
    ("update.install", "Install", "Установить"),
    ("update.manual_body", "This copy of Bridgey can't update itself. Download the new AppImage from the releases page.", "Эта копия Bridgey не обновляется сама. Загрузите новый AppImage со страницы выпусков."),
    ("update.open_releases", "Open releases", "Открыть выпуски"),
    ("update.ready", "Bridgey {0} is ready to install", "Bridgey {0} готов к установке"),
    ("update.up_to_date", "{0}, the latest", "{0}, последняя версия"),
];

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn languages_follow_the_environment() {
        assert_eq!(pick(&[None, Some("ru_RU.UTF-8".into())]), Lang::Ru);
        assert_eq!(pick(&[Some("en_GB:ru".into())]), Lang::En);
        assert_eq!(pick(&[Some("C.UTF-8".into()), Some("ru_UA.UTF-8".into())]), Lang::Ru);
        assert_eq!(pick(&[None]), Lang::En);
    }

    #[test]
    fn every_string_has_both_languages_and_no_duplicates() {
        let mut seen = HashSet::new();
        for (k, en, ru) in STRINGS {
            assert!(seen.insert(*k), "duplicate {k}");
            assert!(!en.is_empty() && !ru.is_empty(), "{k}");
            let placeholders = |s: &str| (0..4).filter(|i| s.contains(&format!("{{{i}}}"))).count();
            assert_eq!(placeholders(en), placeholders(ru), "{k}: the same placeholders");
        }
    }

    #[test]
    fn copy_rules_hold() {
        // No em dashes, British spelling, no eyebrow-style capitals.
        let american = ["color", "favorite", "canceled", "optimize", "behavior", "center", "license ", "organize", "analyze"];
        for (k, en, ru) in STRINGS {
            assert!(!en.contains('\u{2014}') && !ru.contains('\u{2014}'), "{k} has an em dash");
            let lower = en.to_lowercase();
            for word in american {
                assert!(!lower.contains(word), "{k}: American spelling {word:?}");
            }
            assert!(!lower.contains("calm"), "{k}");
        }
    }

    #[test]
    fn every_key_in_the_code_exists() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut missing = Vec::new();
        fn walk(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
            for e in std::fs::read_dir(dir).unwrap().flatten() {
                let p = e.path();
                if p.is_dir() {
                    walk(&p, out);
                } else if p.extension().is_some_and(|x| x == "rs") {
                    out.push(p);
                }
            }
        }
        let mut files = Vec::new();
        walk(&root, &mut files);
        for f in files {
            let text = std::fs::read_to_string(&f).unwrap();
            for pat in ["t(\"", "tf(\""] {
                for (i, _) in text.match_indices(pat) {
                    let before = text[..i].chars().last();
                    if before.is_some_and(|c| c.is_alphanumeric() || c == '_') {
                        continue;
                    }
                    let rest = &text[i + pat.len()..];
                    let key: String = rest.chars().take_while(|c| *c != '"').collect();
                    if key.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '_') && key.contains('.') && lookup(&key, Lang::En).is_none() {
                        missing.push(format!("{}: {key}", f.display()));
                    }
                }
            }
        }
        assert!(missing.is_empty(), "missing strings: {missing:?}");
    }
}
