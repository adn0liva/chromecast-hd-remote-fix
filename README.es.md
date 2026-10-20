# Chromecast HD: el control remoto se desconecta y no vuelve

> **English version:** [README.md](README.md)

Arreglo automático para el **Chromecast con Google TV (HD)** cuando el control remoto
Bluetooth deja de funcionar y solo vuelve borrando los datos de la app Bluetooth y
vinculándolo de nuevo.

## Síntomas

- El control deja de responder (flechas, OK, Home, voz). A veces varias veces al día.
- Reiniciar el Chromecast no siempre lo arregla.
- Lo que sí funciona, pero es cansador: Ajustes → Apps → Bluetooth → **Borrar datos** y
  volver a vincular el control.
- Los botones de volumen y encendido de la tele sí funcionan (esos van por infrarrojo).

## La causa

El control se desconecta solo de vez en cuando (es normal en controles Bluetooth de bajo
consumo). Después de eso, el Chromecast debería quedar **escuchando** al control para que
se reconecte apenas presionas un botón: lo hace anotándolo en una lista del chip
Bluetooth (la *LE accept list*).

En el Chromecast HD esa lista a veces **queda vacía** tras la desconexión. El control
sigue vinculado, pero el Chromecast ya no acepta su reconexión. Por eso:

- **Borrar los datos de Bluetooth** lo arreglaba: reinicia el Bluetooth (eso es lo que
  arregla) y además borra la vinculación (eso sobraba).
- **Reiniciar solo el Bluetooth** basta, y no hay que volver a vincular.

Cómo se ve en `dumpsys bluetooth_manager` (control vinculado, desconectado y fuera de la
lista):

```
shim::legacy::hid   0: addr:xx:xx:xx:xx:yy:zz ... state:BTHH_CONN_STATE_DISCONNECTED
shim::acl Shadow le accept list              size:0   controller_max_size:255
```

Y la pista de que el stack quedó desincronizado, al apagar el Bluetooth:

```
acl.cc:189 Remove: Unknown device being removed from acceptlist:xx:xx:xx:xx:yy:zz
```

En el equipo donde se diagnosticó, el control llevaba **19 días** sin poder reconectarse
en ese estado. Al reiniciar solo el Bluetooth, la lista volvió a tener el control
(`size:1`) y se reconectó con la primera pulsación.

**Descartado** en ese diagnóstico: pilas del control (nivel bueno), firmware del control
(26.7), Wi‑Fi (5 GHz, buena señal), hub USB‑C con Ethernet (pasaba igual por Wi‑Fi) y
cuelgues del Bluetooth (0 crashes). Un Chromecast con Google TV **4K** en la misma casa
nunca tuvo el problema.

## La solución: "Vigilante del control"

Una app mínima, sin pantalla, que:

1. **Arranca sola** cada vez que el Chromecast enciende.
2. Cada **30 segundos** lee `dumpsys bluetooth_manager`.
3. Si el control está **vinculado, desconectado y la lista está vacía** en **dos
   revisiones seguidas**, reinicia el Bluetooth (como máximo una vez cada 3 minutos).
4. Deja un registro de lo que hace.

En el uso normal no notas nada: la falla aparece cuando el control queda inactivo, y el
vigilante la corrige antes de que vuelvas a tomarlo.

Detalles técnicos:

- Necesita el permiso `android.permission.DUMP` para leer el estado del Bluetooth. Ese
  permiso no se puede pedir desde la app: se otorga **una vez por ADB** y queda guardado
  aunque reinicies.
- Reinicia el Bluetooth con `BluetoothAdapter.disable()/enable()`. Desde Android 13 eso
  solo está permitido para apps que apuntan a API 32 o menos; por eso la app declara
  `targetSdkVersion 30` a propósito.
- Solo el sistema y ADB pueden enviarle órdenes (el receptor exige el permiso `DUMP`);
  otras apps no pueden hacerle reiniciar el Bluetooth.
- No necesita root, ni internet, ni un computador encendido.

## Instalación sin IA (paso a paso)

Necesitas un computador en la **misma red** que el Chromecast. Tarda unos 10 minutos.

### 1. Instalar ADB en el computador

- **macOS:** `brew install android-platform-tools`
- **Windows / Linux:** descarga las *SDK Platform-Tools* desde
  <https://developer.android.com/tools/releases/platform-tools> y descomprímelas.

### 2. Activar la depuración en el Chromecast

1. **Ajustes → Sistema → Información → Compilación del SO Android TV**: presiona OK
   **7 veces** hasta que diga que eres desarrollador.
2. **Ajustes → Sistema → Opciones para desarrolladores**: activa **Depuración por USB**
   y **Depuración inalámbrica**.

> **Si tu Chromecast está conectado por cable de red**, la depuración inalámbrica aparece
> deshabilitada: Android solo la permite por **Wi‑Fi**. Desconecta el cable mientras
> instalas; después puedes volver a conectarlo.

> Si el control no te funciona para navegar los menús, usa la app **Google Home** o
> **Google TV** del teléfono como control, o el control de la tele (HDMI‑CEC).

### 3. Vincular el computador con el Chromecast

Entra a **Depuración inalámbrica**. Vas a ver **dos puertos distintos**, y es fácil
confundirlos:

| Dónde aparece | Para qué sirve |
| --- | --- |
| Pantalla principal de *Depuración inalámbrica* | **Conectar** (`adb connect`) |
| Ventana *Vincular dispositivo con código de vinculación* (junto al código de 6 dígitos) | **Vincular** (`adb pair`), solo una vez |

Con la ventana de vinculación abierta:

```bash
adb pair IP:PUERTO_DE_VINCULACION CODIGO
adb connect IP:PUERTO_PRINCIPAL
adb devices
```

`adb devices` debe mostrar el Chromecast como `device`.

> **No ejecutes `adb connect` contra el puerto de vinculación.** Ese servicio atiende una
> conexión a la vez: queda tomado y la vinculación con el código se cuelga.

### 4. (Opcional) Confirmar que tienes esta falla

Cuando el control **no** esté funcionando:

```bash
adb shell dumpsys bluetooth_manager | grep -E "BTHH_CONN_STATE|Shadow le accept list"
```

Si ves `BTHH_CONN_STATE_DISCONNECTED` y `Shadow le accept list ... size:0`, es esta falla.
Para comprobar que reiniciar el Bluetooth lo arregla:

```bash
adb shell cmd bluetooth_manager disable
adb shell cmd bluetooth_manager enable
```

Presiona dos veces un botón del control: debería volver a funcionar (la primera pulsación
lo despierta y lo reconecta; la segunda ya llega a la tele).

### 5. Instalar la app

Descarga `rcu-watchdog.apk` desde la sección **Releases** de este repositorio (o
compílalo, ver más abajo) y ejecuta:

```bash
adb install -r rcu-watchdog.apk
adb shell pm grant com.adan.rcuwatchdog android.permission.DUMP
adb shell am broadcast -a com.adan.rcuwatchdog.START -n com.adan.rcuwatchdog/.BootReceiver -f 0x20
```

El tercer comando la arranca por primera vez. Desde ahí arranca sola en cada encendido.

### 6. Verificar

```bash
adb shell pidof com.adan.rcuwatchdog
adb shell cat /sdcard/Android/data/com.adan.rcuwatchdog/files/vigilante.log
```

Debe mostrar un número de proceso y un log con `vigilante iniciado` y `estado: ok`.

Para probar que puede reiniciar el Bluetooth (el control se desconecta un momento;
vuelve al presionar un botón):

```bash
adb shell am broadcast -a com.adan.rcuwatchdog.TEST_RESTART -n com.adan.rcuwatchdog/.BootReceiver
```

En el log aparece `prueba manual -> reinicio Bluetooth` y luego `tras reinicio: ok`.

Listo. Puedes desactivar la depuración si quieres; la app no la necesita. (En este modelo
la depuración inalámbrica se apaga sola al reiniciar.)

## Instalación con ayuda de Claude

Con [Claude Code](https://claude.com/claude-code) en un computador de la misma red,
activa la depuración (paso 2), abre la ventana de vinculación y pídele algo así:

> Tengo un Chromecast HD con el problema que describe el README de este repositorio
> (`<URL del repo>`). Lee el README. Conéctate por ADB a mi Chromecast: vinculación en
> `IP:PUERTO` con el código `CODIGO`, conexión en `IP:PUERTO_PRINCIPAL`. Antes de instalar
> nada, verifica con `dumpsys bluetooth_manager` si tengo esta falla y explícame lo que
> encuentres. Si la tengo, instala la app siguiendo "Instalación sin IA" y verifica que
> quedó corriendo.

Así se resolvió originalmente: diagnóstico con `dumpsys` y `logcat`, prueba de reiniciar
solo el Bluetooth, un script de vigilancia y, al final, esta app para que sobreviviera
a los reinicios.

## Ver el estado más adelante

```bash
./scripts/estado.sh IP:PUERTO_PRINCIPAL
```

Muestra si la app corre, si tiene el permiso, el estado del control y el log. Las líneas
`control desconectado y fuera de la lista de escucha -> reinicio Bluetooth` son las veces
que el vigilante arregló la falla solo.

Si el Chromecast se reinició, hay que volver a vincular (paso 3).

## Compilar desde el código

Necesitas el Android SDK (build-tools y una plataforma) y un JDK 17 o superior. Con
[Android Studio](https://developer.android.com/studio) instalado ya tienes ambos.

```bash
./app/build.sh
```

Genera `app/build/rcu-watchdog.apk` sin Gradle (`javac` → `d8` → `aapt2` → `zipalign` →
`apksigner`). La primera vez crea una llave de firma propia en `app/signing.jks`, que no
se sube al repositorio. **Guárdala**: para actualizar la app instalada hay que firmar con
la misma llave. Con otra llave, Android obliga a desinstalar primero y a repetir el
`pm grant`.

Si tu SDK o JDK están en otra ruta, define `ANDROID_HOME` y `JAVA_HOME`.

## Desinstalar

```bash
adb uninstall com.adan.rcuwatchdog
```

O desde **Ajustes → Apps → Ver todas las apps → Vigilante del control → Desinstalar**.

## Plan B sin computador

Si algún día el control vuelve a fallar y no tienes la app ni un computador a mano:

**Ajustes → Apps → Ver todas las apps → Mostrar apps del sistema → Bluetooth →
Forzar detención** (no "Borrar datos").

Reinicia el Bluetooth sin perder la vinculación. Después presiona dos veces un botón del
control.

## Cosas a tener en cuenta

- **No uses "Forzar detención" sobre *Vigilante del control*.** Android no entrega el
  aviso de encendido a una app detenida a la fuerza: dejaría de arrancar sola hasta que
  la vuelvas a lanzar con el `am broadcast ... START` del paso 5.
- Al reiniciar el Bluetooth se cortan por unos segundos **todos** los dispositivos
  Bluetooth del Chromecast (audífonos, gamepads), no solo el control.
- Si el Chromecast está en **reposo profundo**, el vigilante se pausa con él. Si alguna
  vez el control no logra encenderlo, enciende la tele con su propio control y espera un
  minuto.
- Probado en un **Chromecast HD**, Android TV 14, compilación `UTTC.250917.004`, con el
  control "Chromecast Remote" (firmware 26.7). El nombre del control está fijo en el
  código (`REMOTE_NAME` en `WatchdogService.java`).
- Si una actualización de Google corrige la falla, el vigilante simplemente nunca va a
  actuar.

## Estructura

```
app/
  AndroidManifest.xml        manifiesto (targetSdk 30, permisos, arranque al encender)
  build.sh                   compilación sin Gradle
  src/com/adan/rcuwatchdog/
    BootReceiver.java        arranca el servicio al encender (o por orden de adb)
    WatchdogService.java     revisión cada 30 s y reinicio del Bluetooth
scripts/
  estado.sh                  estado y log de la app vía adb
  rcu_watchdog.sh            misma lógica como script de shell (sin instalar app;
                             vive hasta el próximo reinicio del Chromecast)
```

## Licencia

[MIT](LICENSE). Úsalo bajo tu propio riesgo: la app reinicia el Bluetooth del
Chromecast y no tiene garantía de ningún tipo.
