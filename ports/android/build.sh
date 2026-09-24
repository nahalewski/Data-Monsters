#!/usr/bin/env bash
# Android APK of the lovepsp runtime (SDL2 activity), packaged with the SDK's
# own tools (aapt2, d8, zipalign, apksigner): no Gradle.
#
#   ANDROID_SDK=/path/to/sdk ANDROID_NDK=/path/to/ndk SDL_DIR=/path/to/SDL-2.30 bash build.sh [build.sh args]
#
# Output: dist/android/gen1recomp.apk (debug-signed).  ROMs go to
# /sdcard/Android/data/com.nahalewski.g1rports/files/ (or roms/ under it).
# Its own package name, so it never replaces or updates the official app.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
SDK="${ANDROID_SDK:-/home/user/android/sdk}"
NDK="${ANDROID_NDK:-$SDK/ndk/26.3.11579264}"
SDL_DIR="${SDL_DIR:-/home/user/android/SDL}"
BT="$SDK/build-tools/${ANDROID_BUILD_TOOLS:-35.0.0}"  # 34.0.0's d8 crashes on anonymous classes with lambdas
PLATFORM="$SDK/platforms/android-34/android.jar"
export MODS_MAX_KB="${MODS_MAX_KB:-999999}"
BUILD_DIR="$ROOT/build_android" bash "$ROOT/build.sh" --host-only "$@"

OUT="$HERE/out"
rm -rf "$OUT/apk" "$OUT/classes" "$OUT/dex" "$OUT/gen-java" "$OUT"/*.apk "$OUT"/*.zip
mkdir -p "$OUT/apk/assets" "$OUT/classes" "$HERE/gen"
python3 "$ROOT/runtime/tools/bin2c.py" "$ROOT/runtime/lua/boot.lua" "$HERE/gen/boot_lua.h" boot_lua
ln -sfn "$SDL_DIR" "$HERE/jni/SDL"
ln -sfn "$SDL_DIR/include" "$HERE/gen/SDL2"  # the runtime includes <SDL2/SDL.h>
"$NDK/ndk-build" -C "$HERE" NDK_PROJECT_PATH="$HERE" APP_BUILD_SCRIPT="$HERE/jni/Android.mk" \
  NDK_APPLICATION_MK="$HERE/jni/Application.mk" NDK_LIBS_OUT="$OUT/apk/lib" NDK_OUT="$OUT/obj" -j"$(nproc)" > "$OUT/ndk-build.log" 2>&1 \
  || { tail -30 "$OUT/ndk-build.log"; exit 1; }

# icon from the PSP art
mkdir -p "$HERE/res/mipmap-xxhdpi"
convert "$ROOT/psp-assets/ICON0.PNG" -resize 144x144 -background '#2a1428' -gravity center -extent 144x144 "$HERE/res/mipmap-xxhdpi/ic_launcher.png"

# resources + manifest
"$BT/aapt2" compile --dir "$HERE/res" -o "$OUT/res.zip"
"$BT/aapt2" link -o "$OUT/base.apk" -I "$PLATFORM" --manifest "$HERE/AndroidManifest.xml" "$OUT/res.zip" \
  --java "$OUT/gen-java" --auto-add-overlay
# java: SDL's activity sources + ours
find "$SDL_DIR/android-project/app/src/main/java" "$HERE/java" "$OUT/gen-java" -name '*.java' > "$OUT/sources.txt"
javac --release 8 -classpath "$PLATFORM" -Xlint:-options -d "$OUT/classes" @"$OUT/sources.txt" 2> "$OUT/javac.log" || { cat "$OUT/javac.log"; exit 1; }
mkdir -p "$OUT/dex"
(cd "$OUT/classes" && jar cf "$OUT/classes.jar" .)
"$BT/d8" --release --min-api 21 --lib "$PLATFORM" --output "$OUT/dex" "$OUT/classes.jar"
# assemble: resources apk + dex + libs + assets
cp "$ROOT/build_android/game.pak" "$OUT/apk/assets/game.pak"
cp "$OUT/dex/classes.dex" "$OUT/apk/classes.dex"
cp "$OUT/base.apk" "$OUT/unaligned.apk"
(cd "$OUT/apk" && zip -q -r "$OUT/unaligned.apk" classes.dex lib assets)
"$BT/zipalign" -f -p 4 "$OUT/unaligned.apk" "$OUT/aligned.apk"
KS="$HERE/debug.keystore"
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass android -keypass android -alias androiddebugkey \
  -dname "CN=Android Debug,O=Android,C=US" -keyalg RSA -keysize 2048 -validity 10000 > /dev/null 2>&1
mkdir -p "$ROOT/dist/android"
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android --out "$ROOT/dist/android/gen1recomp.apk" "$OUT/aligned.apk"
echo "built $ROOT/dist/android/gen1recomp.apk"
