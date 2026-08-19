#!/bin/bash
# Собрать автономный Chirper.app, при необходимости установить и создать DMG.

set -euo pipefail

PROJECT="$(cd "$(dirname "$0")" && pwd)"
ARCH="$(uname -m)"
PYTHON="$PROJECT/.venv/bin/python"
PYINSTALLER="$PROJECT/.venv/bin/pyinstaller"
BUILD_ROOT="$PROJECT/build"
DIST="$PROJECT/dist"
APP="$DIST/Chirper.app"
CONTENTS="$APP/Contents"
EXECUTABLE="$CONTENTS/MacOS/Chirper"
WORKER_DIST="$BUILD_ROOT/worker-dist/ChirperASR"
INSTALL_APP=0
CREATE_DMG=0

for ARGUMENT in "$@"; do
    case "$ARGUMENT" in
        --install) INSTALL_APP=1 ;;
        --dmg) CREATE_DMG=1 ;;
        *) echo "Неизвестный аргумент: $ARGUMENT"; exit 2 ;;
    esac
done

if [ ! -x "$PYTHON" ]; then
    echo "Нет .venv — создайте окружение и установите requirements.txt"
    exit 1
fi
if ! command -v xcrun >/dev/null; then
    echo "Не найдены Xcode Command Line Tools: xcode-select --install"
    exit 1
fi
if [ ! -x "$PYINSTALLER" ]; then
    echo "Не найден PyInstaller — выполните: .venv/bin/pip install -r requirements.txt"
    exit 1
fi

mkdir -p "$BUILD_ROOT" "$DIST"
REBUILD_WORKER=0
if [ ! -x "$WORKER_DIST/ChirperASR" ]; then
    REBUILD_WORKER=1
else
    for SOURCE in \
        "$PROJECT/asr_worker.py" \
        "$PROJECT/asr.py" \
        "$PROJECT/requirements.txt"; do
        if [ "$SOURCE" -nt "$WORKER_DIST/ChirperASR" ]; then
            REBUILD_WORKER=1
        fi
    done
fi

if [ "$REBUILD_WORKER" -eq 1 ]; then
    if [ -d "$BUILD_ROOT/worker-dist" ]; then
        find "$BUILD_ROOT/worker-dist" -depth -delete
    fi
    echo "Собираю автономный ASR-модуль…"
    "$PYINSTALLER" \
        --noconfirm \
        --clean \
        --onedir \
        --name ChirperASR \
        --target-architecture "$ARCH" \
        --distpath "$BUILD_ROOT/worker-dist" \
        --workpath "$BUILD_ROOT/pyinstaller" \
        --specpath "$BUILD_ROOT" \
        --paths "$PROJECT" \
        --copy-metadata onnx-asr \
        --copy-metadata huggingface_hub \
        --collect-data onnx_asr \
        --exclude-module AppKit \
        --exclude-module matplotlib \
        --exclude-module pandas \
        --exclude-module PIL \
        --exclude-module scipy \
        --exclude-module sklearn \
        --log-level WARN \
        "$PROJECT/asr_worker.py"
else
    echo "ASR-модуль не менялся — использую готовую сборку."
fi

if [ ! -x "$WORKER_DIST/ChirperASR" ]; then
    echo "PyInstaller не создал ASR-модуль"
    exit 1
fi

if [ -d "$APP" ]; then
    find "$APP" -depth -delete
fi
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$PROJECT/native/Info.plist" "$CONTENTS/Info.plist"
cp "$PROJECT/native/Chirper.icns" "$CONTENTS/Resources/Chirper.icns"
cp "$PROJECT/LICENSE" "$CONTENTS/Resources/LICENSE.txt"
cp "$PROJECT/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"
cp -R "$WORKER_DIST" "$CONTENTS/Resources/ASR"

xcrun swiftc \
    -swift-version 5 \
    -O \
    -target "$ARCH-apple-macos13.0" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework AVFoundation \
    -framework CoreAudio \
    "$PROJECT/native/Chirper.swift" \
    -o "$EXECUTABLE"

# Явное designated requirement сохраняет системные разрешения между
# локальными ad-hoc сборками, хотя не заменяет Developer ID и нотарификацию.
codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "com.chirper.dictation"' \
    "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

echo "Собрано: $APP"
echo "Размер: $(du -sh "$APP" | cut -f1)"

if [ "$INSTALL_APP" -eq 1 ]; then
    INSTALLED_APP="/Applications/Chirper.app"
    INSTALLED_CONTENTS="$INSTALLED_APP/Contents"
    pkill -f "$INSTALLED_APP/Contents/MacOS/Chirper" 2>/dev/null || true
    pkill -f "$INSTALLED_APP/Contents/Resources/ASR/ChirperASR" 2>/dev/null || true

    # Корневую .app сохраняем: Dock и Login Items держат bookmark на её inode.
    if [ -d "$INSTALLED_CONTENTS" ]; then
        find "$INSTALLED_CONTENTS" -mindepth 1 -depth -delete
    fi
    mkdir -p "$INSTALLED_CONTENTS"
    cp -R "$CONTENTS/." "$INSTALLED_CONTENTS/"
    codesign --verify --deep --strict "$INSTALLED_APP"
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
        -f "$INSTALLED_APP" >/dev/null 2>&1 || true
    echo "Установлено: $INSTALLED_APP"
fi

if [ "$CREATE_DMG" -eq 1 ]; then
    VERSION="$(plutil -extract CFBundleShortVersionString raw "$PROJECT/native/Info.plist")"
    DMG="$DIST/Chirper-$VERSION-$ARCH.dmg"
    STAGE="$(mktemp -d /tmp/chirper-dmg.XXXXXX)"
    cp -R "$APP" "$STAGE/Chirper.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname Chirper -srcfolder "$STAGE" -ov -format UDZO "$DMG"
    find "$STAGE" -depth -delete
    echo "Дистрибутив: $DMG ($(du -sh "$DMG" | cut -f1))"
fi
