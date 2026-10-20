package com.adan.rcuwatchdog;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.bluetooth.BluetoothAdapter;
import android.content.Intent;
import android.os.IBinder;
import android.os.SystemClock;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileWriter;
import java.io.InputStream;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Falla que corrige: cuando el control se desconecta (p. ej. por inactividad), el
 * stack Bluetooth del Chromecast HD a veces no lo vuelve a poner en la lista de
 * escucha del chip ("Shadow le accept list size:0"). El control sigue vinculado,
 * pero el Chromecast ya no acepta su reconexión. Reiniciar el Bluetooth vuelve a
 * armar la lista sin perder la vinculación.
 *
 * Misma lógica que rcu_watchdog.sh: revisa cada 30 s y, si la falla se repite en
 * dos revisiones seguidas, reinicia el Bluetooth (como máximo cada 3 minutos).
 */
public class WatchdogService extends Service {
    static final String TAG = "RcuWatchdog";
    static final String ACTION_TEST_RESTART = "com.adan.rcuwatchdog.TEST_RESTART";

    private static final String REMOTE_NAME = "Chromecast Remote";
    private static final int INTERVAL_S = 30;
    private static final int CONFIRM = 2;
    private static final long COOLDOWN_MS = 180_000;
    private static final long LOG_MAX_BYTES = 100_000;

    private static final Pattern ADAPTER_STATE = Pattern.compile("(?m)^  state: (\\S+)");
    private static final Pattern BONDED_REMOTE = Pattern.compile(
            "(?m)^\\s+([0-9A-F:]{17}) \\[.*\\] " + Pattern.quote(REMOTE_NAME) + "\\s*$");
    private static final Pattern EMPTY_ACCEPT_LIST = Pattern.compile("Shadow le accept list +size:0 ");

    private Thread worker;
    private volatile boolean testRestart;

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(
                "watchdog", "Vigilante", NotificationManager.IMPORTANCE_MIN));
        Notification notification = new Notification.Builder(this, "watchdog")
                .setContentTitle("Vigilante del control remoto")
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .build();
        startForeground(1, notification);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_TEST_RESTART.equals(intent.getAction())) {
            testRestart = true;
        }
        if (worker == null || !worker.isAlive()) {
            worker = new Thread(new Runnable() {
                @Override
                public void run() {
                    loop();
                }
            }, "rcu-watchdog");
            worker.start();
        }
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void loop() {
        log("vigilante iniciado");
        int strikes = 0;
        long lastFix = -COOLDOWN_MS;
        String previous = "";
        while (true) {
            if (testRestart) {
                testRestart = false;
                log("prueba manual -> reinicio Bluetooth");
                restartBluetooth();
                sleep(10);
                log("tras reinicio: " + diagnose());
            }
            String d = diagnose();
            // Solo registra cambios de estado, para no llenar el log cada 30 s
            if (!d.equals(previous)) {
                log("estado: " + d);
                previous = d;
            }
            if (d.equals("falla")) {
                strikes++;
                long now = SystemClock.elapsedRealtime();
                if (strikes >= CONFIRM && now - lastFix >= COOLDOWN_MS) {
                    log("control desconectado y fuera de la lista de escucha -> reinicio Bluetooth");
                    restartBluetooth();
                    lastFix = now;
                    strikes = 0;
                    sleep(10);
                    previous = diagnose();
                    log("tras reinicio: " + previous);
                }
            } else {
                strikes = 0;
            }
            sleep(INTERVAL_S);
        }
    }

    /** Devuelve: ok | falla | sin_control | bt_apagado | buscando | error: ... */
    private String diagnose() {
        String st;
        try {
            st = dumpBluetooth();
        } catch (Exception e) {
            return "error: " + e;
        }
        if (!st.contains("Bluetooth Status")) {
            return "error: dumpsys sin datos (" + st.substring(0, Math.min(120, st.length())).trim() + ")";
        }
        Matcher state = ADAPTER_STATE.matcher(st);
        if (!state.find() || !state.group(1).equals("ON")) return "bt_apagado";
        if (st.contains("Discovering: true")) return "buscando";

        Matcher bonded = BONDED_REMOTE.matcher(st);
        if (!bonded.find()) return "sin_control";
        // El dump enmascara los primeros 4 octetos: se compara por los 2 últimos
        String tail2 = bonded.group(1).substring(12).toLowerCase(Locale.ROOT);
        if (Pattern.compile("addr:xx:xx:xx:xx:" + tail2 + " .*state:BTHH_CONN_STATE_CONNECTED")
                .matcher(st).find()) {
            return "ok";
        }
        // Control vinculado y desconectado: normal solo si está en la lista de escucha
        return EMPTY_ACCEPT_LIST.matcher(st).find() ? "falla" : "ok";
    }

    @SuppressWarnings("deprecation")
    private void restartBluetooth() {
        BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
        if (!adapter.disable()) log("disable() devolvió false");
        // getState() dice OFF cuando se apaga la parte clásica, pero BLE sigue
        // apagándose; se espera al OFF completo del gestor para no encender a medias
        for (int i = 0; i < 20 && !"OFF".equals(managerState()); i++) sleep(1);
        if (!adapter.enable()) log("enable() devolvió false");
    }

    /** Estado del gestor de Bluetooth según dumpsys (ON, OFF, BLE_TURNING_OFF, ...). */
    private String managerState() {
        try {
            Matcher m = ADAPTER_STATE.matcher(dumpBluetooth());
            return m.find() ? m.group(1) : "";
        } catch (Exception e) {
            return "";
        }
    }

    /** Requiere el permiso DUMP (otorgado por adb con pm grant). */
    private static String dumpBluetooth() throws Exception {
        Process p = new ProcessBuilder("/system/bin/dumpsys", "bluetooth_manager")
                .redirectErrorStream(true).start();
        String out = readAll(p.getInputStream());
        p.waitFor();
        return out;
    }

    private void log(String msg) {
        Log.i(TAG, msg);
        File dir = getExternalFilesDir(null);
        if (dir == null) return;
        File file = new File(dir, "vigilante.log");
        if (file.length() > LOG_MAX_BYTES) {
            file.renameTo(new File(dir, "vigilante.log.1"));
        }
        String ts = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.ROOT).format(new Date());
        try (FileWriter w = new FileWriter(file, true)) {
            w.write(ts + " " + msg + "\n");
        } catch (Exception e) {
            Log.w(TAG, "no pude escribir el log", e);
        }
    }

    private static String readAll(InputStream in) throws java.io.IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        return out.toString("UTF-8");
    }

    private static void sleep(int seconds) {
        SystemClock.sleep(seconds * 1000L);
    }
}
