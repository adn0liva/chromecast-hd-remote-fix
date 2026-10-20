#!/usr/bin/env bash
# Muestra el estado y el log de la app "Vigilante del control" en el Chromecast HD.
# Requiere Depuración inalámbrica activa (se apaga sola al reiniciar el Chromecast).
#
# Uso:  ./estado.sh IP:PUERTO   (IP:puerto de la pantalla principal de Depuración inalámbrica)

ADB=$(command -v adb || echo ~/Library/Android/sdk/platform-tools/adb)
[[ -z ${1:-} ]] && { echo "Uso: $0 IP:PUERTO"; exit 1; }
$ADB connect "$1" >/dev/null
export ANDROID_SERIAL=$1
$ADB get-state >/dev/null 2>&1 || {
  echo "No pude conectar. Si el Chromecast se reinició, vuelve a vincular:"
  echo "  $ADB pair IP:PUERTO_DE_VINCULACION CODIGO"
  exit 1
}

echo "App corriendo:   $($ADB shell pidof com.adan.rcuwatchdog >/dev/null && echo sí || echo NO)"
echo "Permiso DUMP:    $($ADB shell dumpsys package com.adan.rcuwatchdog | grep -m1 -o 'DUMP: granted=[a-z]*')"
echo "Bluetooth:       $($ADB shell dumpsys bluetooth_manager | grep -m1 -E '^  state:' | awk '{print $2}')"
echo "Control:         $($ADB shell dumpsys bluetooth_manager | grep -m1 -oE 'BTHH_CONN_STATE_[A-Z]+')"
echo "--- log ---"
$ADB shell cat /sdcard/Android/data/com.adan.rcuwatchdog/files/vigilante.log
