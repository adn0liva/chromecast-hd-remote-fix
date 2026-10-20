#!/usr/bin/env bash
# Compila la app del vigilante sin Gradle: javac -> d8 -> aapt2 -> zipalign -> apksigner.
# Resultado: build/rcu-watchdog.apk
#
# Necesita el Android SDK (build-tools + una plataforma) y un JDK 17+. Si tienes
# Android Studio instalado, ya tienes ambos. Variables opcionales:
#   ANDROID_HOME   ruta al SDK (por defecto la de Android Studio)
#   JAVA_HOME      ruta al JDK (por defecto el JDK que trae Android Studio)
#   RCU_KS_PASS    contraseña de la llave de firma (por defecto "rcuwatchdog")
set -euo pipefail
cd "$(dirname "$0")"

first_dir() { for d in "$@"; do [[ -n $d && -d $d ]] && { echo "$d"; return; }; done; }
latest() { ls "$1" 2>/dev/null | sort -V | tail -1; }

SDK=$(first_dir "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" ~/Library/Android/sdk ~/Android/Sdk)
[[ -z $SDK ]] && { echo "No encontré el Android SDK. Define ANDROID_HOME." >&2; exit 1; }
BT=$SDK/build-tools/$(latest "$SDK/build-tools")
PLATFORM=$SDK/platforms/$(latest "$SDK/platforms")/android.jar
[[ -f $PLATFORM && -x $BT/d8 ]] || { echo "Faltan build-tools o una plataforma en $SDK" >&2; exit 1; }

JAVA_HOME=$(first_dir "${JAVA_HOME:-}" \
  "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
  ~/android-studio/jbr /opt/android-studio/jbr)
[[ -z $JAVA_HOME ]] && { echo "No encontré un JDK. Define JAVA_HOME." >&2; exit 1; }
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$BT:$PATH"

echo "SDK: $SDK | build-tools: ${BT##*/} | plataforma: $(basename "$(dirname "$PLATFORM")")"

rm -rf build && mkdir -p build/classes build/dex

javac -source 8 -target 8 -bootclasspath "$PLATFORM" -Xlint:-options \
  -d build/classes src/com/adan/rcuwatchdog/*.java

d8 --min-api 28 --lib "$PLATFORM" --output build/dex build/classes/com/adan/rcuwatchdog/*.class

aapt2 link -o build/unsigned.apk --manifest AndroidManifest.xml -I "$PLATFORM"
(cd build/dex && zip -q ../unsigned.apk classes.dex)

zipalign -f -p 4 build/unsigned.apk build/aligned.apk

# Llave de firma propia: se genera la primera vez y NO va al repo (.gitignore).
# Para actualizar la app instalada hay que firmar con la misma llave; con otra,
# Android obliga a desinstalar primero (y a repetir el pm grant).
KS_PASS=${RCU_KS_PASS:-rcuwatchdog}
if [[ ! -f signing.jks ]]; then
  keytool -genkeypair -keystore signing.jks -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -alias rcu -keyalg RSA -keysize 2048 -validity 20000 -dname "CN=rcu-watchdog" >/dev/null 2>&1
fi
apksigner sign --ks signing.jks --ks-pass "pass:$KS_PASS" --ks-key-alias rcu \
  --out build/rcu-watchdog.apk build/aligned.apk 2>/dev/null

echo "OK: $(pwd)/build/rcu-watchdog.apk"
