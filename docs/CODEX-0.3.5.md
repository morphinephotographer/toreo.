# toreo. 0.3.5 (сборка 8) — задание для Codex

Ветка `fix/review-0.3.5` содержит исправления по ревью Claude версии 0.3.4 (сборка 7). Изменения написаны без доступа к macOS: код не компилировался и не запускался. Задача Codex — собрать, прогнать проверки, исправить ошибки компиляции и подтвердить поведение на Mac.

## Что изменено

| # | Изменение | Файлы |
|---|---|---|
| 1 | Предупреждения и ошибки трекера (`error` 1 и 2) больше не останавливают волну, не скрывают галочку и не убирают кнопку паузы. Ошибкой считается только `error == 3` (`Transfer.hasLocalError`). Текст трекера виден в подсказке, повторный запрос — в контекстном меню. | `Engine.swift`, `MenuBarIcon.swift`, `MenuPanel.swift` |
| 2 | Выход возвращает `.terminateLater` и вызывает `reply(toApplicationShouldTerminate: true)` после `store.close()`. Logout, перезагрузка и выключение macOS больше не отменяются. | `App.swift` |
| 3 | Скрытое главное меню с пунктами «Правка» (⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘A) и ⌘Q. Обновляется при смене языка. | `App.swift`, `Store.swift`, `Localization.swift` |
| 4 | `ProblemAction.resolve` больше не разбирает локализованные строки toreo.: при `missingFile` всегда «Проверить файл». На `No data found … "Set Location"` — «Выбрать папку». | `MenuPanel.swift`, `AppCheck.swift` |
| 5 | Один клик по значку подтверждает всю очередь завершений. Если панель открыта, клик её закрывает. Клик в течение 0,3 с после закрытия transient-поповера не открывает его снова. | `MenuBarIcon.swift`, `Indicators.swift` |
| 6 | Автоимпорт: файл с ошибкой запоминается по размеру и дате изменения, сообщение появляется один раз. Закрытое сообщение не возвращается без новой ошибки. Смена папки загрузки — повод проверить файлы ещё раз. | `Engine.swift`, `Store.swift` |
| 7 | Автоимпорт: при первом просмотре папки файлы, которые уже в ней лежат, только записываются в журнал и не запускаются. Список просмотренных папок хранится в `auto-import-folders.json`. Если `auto-import.json` уже существует, текущая папка считается просмотренной — для действующих установок поведение не меняется. | `Engine.swift` |
| 8 | Порт для пиров выбирается один раз (49152–65535) и сохраняется. `peer_port_random_on_start` принудительно `false`. Мост больше не выключает `port_forwarding_enabled` (по умолчанию в Transmission включено). `engine-check.py` выключает проброс явно. | `Engine.swift`, `Engine/Bridge.cc`, `tools/engine-check.py` |
| 9 | Удалённые передачи убираются из очереди галочек. Переходы `complete` во время проверки (`status` 1/2) не считаются новым завершением. | `MenuBarIcon.swift`, `Engine.swift` |
| 10 | «Удалить с файлами» переносит в Корзину и папки, которые стали пустыми (допускается только `.DS_Store`), начиная с самых глубоких, внутри `downloadDir`. | `Engine.swift` |
| 11 | ⌥ + «Торрент-файл» открывает форму `ImportPanel` с выбором папки и файлов (`Store.chooseFileWithOptions`). | `Store.swift`, `MenuPanel.swift` |
| 12 | `RILL_QUIT_CHECK` требует `RILL_STORE`. | `AppCheck.swift` |
| 13 | Поле magnet получает фокус через `.task` + `Task.yield()` и при `NSPopover.didShowNotification`. | `MenuPanel.swift` |
| 14 | В строках настроек есть подпись и значение (`TransferRowText`). У полей поиска и magnet — обводка. «Удалить с файлами» — полужирным. У карточек без действия убран признак кнопки для VoiceOver. `MenuCircle(localized: false)` для имён файлов. | `Views.swift`, `MenuPanel.swift` |

Также: версия 0.3.5 (8), `NSDownloadsFolderUsageDescription` в `Info.plist`, README обновлён.

## Что сделать

1. Переключиться на ветку: `git fetch origin && git checkout fix/review-0.3.5`.
2. Собрать: `./build.sh`. Исправить ошибки компиляции Swift 6 минимальными правками, не меняя поведения из таблицы. Места, где ошибки вероятнее всего:
   - `MenuPanel.swift`: `let` внутри `if let trackerMessage` в `.contextMenu`, `.accessibilityRemoveTraits(... ? AccessibilityTraits() : .isButton)`, `.onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification))`. Для `onReceive` может понадобиться `import Combine`.
   - `Indicators.swift`: соответствие `NSPopoverDelegate` и изоляция `popoverDidClose`.
   - `App.swift`: `Selector(("undo:"))`, `static func installMainMenu()`, вызов из `Store.language.didSet`.
   - `Engine.swift`: строка `#"…\#(Int.random(in: 49152...65535))…"#`.
3. Прогнать проверки (все с временными папками, без настоящих данных):

   ```bash
   python3 tools/engine-check.py toreo..app/Contents/Frameworks/libRillEngine.dylib <локальный IPv4>
   RILL_STORE=$(mktemp -d) RILL_APP_CHECK=<копия review/fixture.torrent во временной папке> ./toreo..app/Contents/MacOS/Toreo
   RILL_STORE=$(mktemp -d) RILL_QUIT_CHECK=<тестовый .torrent> ./toreo..app/Contents/MacOS/Toreo
   RILL_SNAPSHOT_DIR=/tmp/toreo-snapshots ./toreo..app/Contents/MacOS/Toreo
   RILL_STATUS_SNAPSHOT_DIR=/tmp/toreo-status ./toreo..app/Contents/MacOS/Toreo
   ```

   Новые и изменённые проверки:
   - `AppCheck`: действия при ошибке во всех трёх языках; автоимпорт с первым просмотром папки, повреждённым файлом и новым файлом.
   - `Snapshot.checkStatusIcon`: предупреждение трекера, подтверждение всей очереди, закрытие и повторное открытие панели кликом по значку.
4. Проверить руками на Mac:
   - ⌘V, ⌘A, ⌘C в поле magnet и в поиске. В режиме значка Dock в строке меню появляется «Правка».
   - Выход из системы при запущенном toreo. с активной загрузкой: logout проходит, после входа передача восстанавливается.
   - Клик по значку при открытой панели закрывает её и не открывает снова.
   - Закрыть панель с открытым полем magnet и открыть снова: курсор в поле.
   - ⌥ + «Торрент-файл» открывает форму, «Назад» и Esc возвращают к списку, «Добавить» запускает с выбранными файлами.
   - «Проверить файлы» на завершённой раздаче не вызывает галочку и звук.
   - «Удалить с файлами» для многофайловой раздачи не оставляет пустую папку.
   - Контраст вторичного текста в светлой теме на светлых и тёмных обоях. Если не хватает — предложить правку, не меняя сетку.
5. Обновить снимки в `review/` и журналы проверок, собрать пакет ревью и установочный ZIP так же, как для 0.3.4. Влить ветку в `main` после зелёных проверок.

## Чего не менять

- Папку данных `~/Library/Application Support/Rill/Engine` и идентификатор `local.rill.torrent`.
- Безопасность удаления: проверки префикса, символических ссылок и чужих файлов в `Engine.trashFiles`.
- Сетку 384 pt, кнопки 40 pt, отступы 8 pt.
