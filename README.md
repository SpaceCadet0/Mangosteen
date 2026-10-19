# Mangosteen

Офлайн-конвертер файлов для macOS «в ноль кликов». Начните перетаскивать файл, коротко нажмите
клавишу-модификатор, и у курсора появится колесо. Бросьте файл на нужный сегмент, и результат
появится рядом с оригиналом.

| Клавиша во время перетаскивания | Колесо |
|---|---|
| `⇧ Shift` | Конвертация: изображения (PNG, JPG, WebP, HEIC, TIFF, AVIF, BMP, GIF, PDF; вход SVG, PSD, ICO…), PDF → картинки/текст/DOCX, документы DOCX/ODT/RTF/RTFD/TXT/Markdown/HTML ↔ друг в друга и в PDF, субтитры SRT/VTT, таблицы CSV/TSV, архивы ZIP/TAR/TAR.GZ (и папки → архив) |
| `⌘ Command` | Инструменты: сжатие (пресет, качество, целевой размер, ресайз, смена формата; PDF), обрезка (рамка, пропорции, точный размер), PDF из фото, объединение PDF, распаковка архивов (список будет расширяться) |
| `⌃ Control` | Действия: AirDrop, Float (плавающая полка для файлов), копировать, переместить, скопировать путь, открыть в терминале |

Клавиши настраиваются в «Настройках». Всё работает локально, без лимитов и без отправки файлов куда-либо.
Без перетаскивания то же самое доступно через меню в строке меню: выберите файлы и кликните по сегменту.

Подробный план развития: [docs/PLAN.md](docs/PLAN.md).

## Сборка

Требования: macOS 14+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Для WebP нужен `cwebp`, позже понадобятся `ffmpeg` и `exiftool`:

```bash
brew install xcodegen webp ffmpeg exiftool
```

```bash
xcodegen generate
xcodebuild -scheme Mangosteen -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Mangosteen.app
```

Тесты:

```bash
xcodebuild -scheme Mangosteen -derivedDataPath build test
```

Приложение не использует песочницу и подписывается ad-hoc. Оно предназначено для личного использования.
