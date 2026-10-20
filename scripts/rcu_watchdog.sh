#!/system/bin/sh
# Vigilante del control remoto del Chromecast HD (Android TV 14, build UTTC.250917.004).
#
# Falla que corrige: cuando el control se desconecta (p. ej. por inactividad), el
# stack Bluetooth del Chromecast HD a veces no lo vuelve a poner en la lista de
# escucha del chip ("Shadow le accept list size:0"). El control sigue vinculado,
# pero el Chromecast ya no acepta su reconexión y parece "desvinculado".
# Reiniciar el Bluetooth vuelve a armar la lista sin perder la vinculación.
#
# El script corre como usuario shell (lanzado por adb) y vive hasta el próximo
# reinicio del Chromecast. Alternativa a la app cuando no se quiere instalar nada.
# Lanzarlo desde el computador:
#   adb push rcu_watchdog.sh /data/local/tmp/
#   adb shell "setsid nohup sh /data/local/tmp/rcu_watchdog.sh > /dev/null 2>&1 < /dev/null &"
# Ver el log:      adb shell cat /data/local/tmp/rcu_watchdog.log
# Diagnóstico:     adb shell sh /data/local/tmp/rcu_watchdog.sh check
# Detenerlo:       adb shell 'kill $(cat /data/local/tmp/rcu_watchdog.pid)'
# No lo uses junto con la app: serían dos vigilantes reiniciando el Bluetooth.

DIR=/data/local/tmp
LOG=$DIR/rcu_watchdog.log
PIDFILE=$DIR/rcu_watchdog.pid
REMOTE_NAME="Chromecast Remote"   # nombre con que aparece el control en "Bonded devices"
INTERVAL=30     # segundos entre revisiones
CONFIRM=2       # revisiones seguidas con la falla antes de actuar
COOLDOWN=180    # segundos mínimos entre dos reinicios de Bluetooth

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
  # Mantiene el log acotado (~100 KB)
  if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 100000 ]; then
    tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

# Devuelve: ok | falla | sin_control | bt_apagado | buscando
diagnose() {
  st=$(dumpsys bluetooth_manager 2>/dev/null)
  echo "$st" | grep -m1 -E '^  state:' | grep -q 'state: ON$' || { echo bt_apagado; return; }
  echo "$st" | grep -q 'Discovering: true' && { echo buscando; return; }
  # MAC del control vinculado (ej. AA:BB:CC:DD:EE:FF); el dump enmascara los
  # primeros 4 octetos, así que se compara por los 2 últimos en minúsculas
  mac=$(echo "$st" | grep -A10 '^  Bonded devices:' | grep -m1 "$REMOTE_NAME" | awk '{print $1}')
  [ -z "$mac" ] && { echo sin_control; return; }
  tail2=$(echo "$mac" | cut -d: -f5-6 | tr 'A-F' 'a-f')
  echo "$st" | grep -qE "addr:xx:xx:xx:xx:$tail2 .*state:BTHH_CONN_STATE_CONNECTED" && { echo ok; return; }
  # Control vinculado y desconectado: normal solo si está en la lista de escucha
  if echo "$st" | grep -qE 'Shadow le accept list +size:0 '; then
    echo falla
  else
    echo ok
  fi
}

restart_bt() {
  cmd bluetooth_manager disable >/dev/null 2>&1
  i=0
  while [ $i -lt 20 ]; do
    dumpsys bluetooth_manager 2>/dev/null | grep -m1 -E '^  state:' | grep -q 'OFF' && break
    sleep 1; i=$((i + 1))
  done
  cmd bluetooth_manager enable >/dev/null 2>&1
}

if [ "$1" = "check" ]; then
  diagnose
  exit 0
fi

# Evita dos instancias a la vez
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "ya está corriendo (pid $(cat "$PIDFILE"))"
  exit 0
fi
echo $$ > "$PIDFILE"
log "vigilante iniciado (pid $$)"

strikes=0
last_fix=0
while true; do
  d=$(diagnose)
  if [ "$d" = "falla" ]; then
    strikes=$((strikes + 1))
    now=$(date +%s)
    if [ $strikes -ge $CONFIRM ] && [ $((now - last_fix)) -ge $COOLDOWN ]; then
      log "control desconectado y fuera de la lista de escucha -> reinicio Bluetooth"
      restart_bt
      last_fix=$now
      strikes=0
      sleep 10
      log "tras reinicio: $(diagnose)"
    fi
  else
    strikes=0
  fi
  sleep $INTERVAL
done
