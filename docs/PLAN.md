# Mangosteen — план разработки

Mangosteen — офлайн-конвертер файлов для macOS «в ноль кликов», вдохновлённый Tangerine.
Приложение для личного использования: без paywall, без лимитов, без телеметрии.
Весь код пишется с нуля; из Tangerine ничего не копируется (ни код, ни ресурсы).

## 1. Что делает исходный продукт (результаты исследования)

### Модель взаимодействия
- Агент в строке меню (`LSUIElement`), без иконки в Dock, запускается при входе в систему.
- Пользователь **начинает тащить** файл(ы) из Finder (или любого приложения) и, не отпуская мышь,
  **коротко нажимает модификатор**. У курсора появляется «колесо» (веер) с вариантами.
  Колесо остаётся открытым, пока файл не будет брошен:
  - на сегмент — выполняется действие;
  - мимо — колесо закрывается.
- Три колеса (модификаторы настраиваются в Settings):
  - `⇧ Shift` — **конвертация форматов** (сегменты = целевые форматы для типа файла);
  - `⌘ Command` — **файловые инструменты** (Compress, Metadata, Edit, Annotate, Crop…);
  - `⌃ Control` — **файловые действия** (AirDrop, Float, Copy, Move, Copy Path, Terminal).
- Результат сохраняется **рядом с оригиналом**, оригинал не меняется. При конфликте имён
  добавляется суффикс (`photo 2.png`).
- Звуковой и тактильный отклик при наведении на сегмент.
- Окно прогресса для долгих операций; у инструментов — отдельное окно настроек с live-превью.
- Float — плавающая «полка» для файлов: прикрепляется к краю экрана, из неё файлы можно утащить в другое приложение.
- Онбординг (welcome wheel), настройки: модификаторы, звук/хаптика, автозапуск, доступ к папкам,
  настройки конвертации по умолчанию для каждого выходного формата (качество, пресеты).

### Стек Mangosteen
- UI: Swift, AppKit + SwiftUI.
- Изображения: ImageIO (JPG/PNG/HEIC/TIFF/AVIF/BMP/GIF/PDF) + `cwebp` для WebP.
- Видео/аудио: `ffmpeg` из Homebrew, позже вшитый в бандл.
- Метаданные: ImageIO + ExifTool.
- PDF: PDFKit. Документы: NSAttributedString / `textutil`.
- Office (PPTX/XLSX) не делаем. Лимитов нет.

Наше приложение не в песочнице (личное использование, ad-hoc подпись), поэтому
не нужен экран «разрешите доступ к домашней папке».

## 2. Архитектура

```
Mangosteen/
  App/            AppDelegate, MenuBarController, точка входа
  Core/           DragMonitor (глобальный drag + модификаторы), FileKind, FormatCatalog, OutputNaming
  Wheel/          WheelPanel (неактивирующая NSPanel у курсора), WheelView (сегменты-цели drop)
  Conversion/     Converter-протокол, ImageConverter, PDFConverter, DocumentConverter,
                  MediaConverter (ffmpeg), ConversionService (очередь + прогресс)
  Tools/          Compress, Metadata, Crop, Edit, Annotate, Background, Redact, Collage, PDF merge/organize …
  Actions/        AirDrop, Float, Copy, Move, CopyPath, Terminal
  Settings/       AppSettings (UserDefaults), SettingsView (SwiftUI)
  Support/        ExternalTool (поиск бинарников: bundle → /opt/homebrew → /usr/local), Process-обёртка
MangosteenTests/  юнит-тесты конвертеров, именования, каталога форматов
```

### Ключевой механизм «zero-click»
1. `NSEvent.addGlobalMonitorForEvents` на `.leftMouseDragged` / `.leftMouseUp` — работает без
   разрешения Accessibility.
2. Начало drag детектируется по изменению `NSPasteboard(name: .drag).changeCount`; из него читаются URL файлов.
3. Модификаторы опрашиваются через `NSEvent.modifierFlags` во время drag (+ глобальный монитор
   `.flagsChanged`, если доступен). «Тап» = нажатие и отпускание модификатора без других клавиш.
4. По тапу показывается `NSPanel` (`.nonactivatingPanel`, уровень `.popUpMenu`) с колесом.
   Каждый сегмент — `NSDraggingDestination`; drop на сегмент → выполнить действие над URL из drag-pasteboard.
5. `leftMouseUp` вне колеса → закрыть колесо.

## 3. Фазы

Каждая фаза заканчивается коммитом и push в GitHub.

### Фаза 0 — каркас и проверка рисков ✅
- XcodeGen-проект, menu bar агент, настройки, README, .gitignore.
- DragMonitor + колесо + drop на сегмент.
- Конвертация изображений через ImageIO, сохранение рядом с оригиналом.
- Юнит-тесты именования и конвертации.

### Фаза 1 — изображения полностью ✅ (кроме макс. размера — переезжает в Compress)
- Форматы: JPG, PNG, WebP (cwebp), HEIC, TIFF, AVIF, BMP, GIF, PDF; вход SVG (NSImage; в PDF — вектором), анимированный GIF → WebP (gif2webp), ICO/ICNS, PSD (только вход).
- Настройки конвертации для формата (качество, сохранение метаданных, макс. размер).
- Пакетные drop'ы (много файлов, смешанные типы → только общие форматы), окно прогресса.
- «Create a PDF» из нескольких изображений.

### Фаза 2 — PDF и документы ✅ (кроме PDF → EPUB)
- PDF → JPG/PNG (все страницы, 300 DPI, папка), PDF → TXT/MD/RTF/DOCX/HTML (текстовый слой), PDF → EPUB (простой).
- DOCX/RTF/RTFD/TXT/MD/HTML/ODT ↔ друг в друга и → PDF (NSAttributedString / textutil, MD — свой парсер).
- Субтитры SRT ↔ VTT, → TXT.
- Таблицы CSV ↔ TSV (без Office).
- Архивы: ZIP/TAR/GZIP упаковка и распаковка (`ditto`, `tar`, `gzip`).

### Фаза 3 — файловые действия (⌃ колесо) ✅ (прилипание к краю и несколько полок — позже)
- AirDrop (`NSSharingService(.sendViaAirDrop)`), Copy (файлы в pasteboard), Move (выбор папки),
  Copy Path, Terminal (Terminal / iTerm2 по настройке).
- Float: плавающая полка, прилипание к краю, перетаскивание наружу, Quick Look, несколько полок.

### Фаза 4 — файловые инструменты (⌘ колесо), окно инструмента с превью ✅
- Compress (целевой размер / % / пресет, ресайз), Edit metadata (ImageIO + exiftool), Crop (соотношения, точные размеры),
  Edit photos (Core Image: экспозиция, цвет, резкость, шум, зерно…), Annotate (стрелки, текст, фигуры, номера),
  Add background (цвет, градиент, картинка, скругление, тень, соотношение), Redact (Vision: лица/текст; заливка/блюр),
  Collage (сетка/ряд/колонка/featured).
- PDF: Merge PDFs, Organize pages (поворот, дублирование, удаление, порядок).

### Фаза 5 — видео и аудио (ffmpeg) ✅
- Конвертация MP4/MOV/MKV/WebM/AVI/WMV/GIF, MP3 из видео; аудио MP3/M4A/WAV/FLAC/OGG/Opus/AIFF/WMA.
- Инструменты: Trim, Crop, Speed, Join, Save frames, Split, Redact video; Normalize, Visualizer, Trim audio, Channels, Bleep.
- Прогресс по выводу ffmpeg (`-progress pipe:1`), отмена.

### Фаза 6 — полировка и автономность
- Онбординг, звук/хаптика, иконка, автозапуск (`SMAppService.mainApp`).
- Скрипт `scripts/bundle-tools.sh`: вшить ffmpeg/cwebp/exiftool в `.app` (поиск в бандле имеет приоритет).
- Скрипт сборки релиза и установки в /Applications.

## 4. Принципы
- Оригинал никогда не изменяется; запись атомарная (во временный файл → переименование).
- Каждый конвертер — чистая функция `input URL + options → output URL`, покрыта тестами.
- Ошибки показываются пользователю (уведомление/окно), а не теряются.
- Внешние бинарники вызываются через `Process` с массивом аргументов (без shell-интерполяции).
