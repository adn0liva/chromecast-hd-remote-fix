package com.adan.rcuwatchdog;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Arranca el vigilante al encender el Chromecast (o a pedido desde adb). */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        Intent service = new Intent(context, WatchdogService.class);
        String action = intent.getAction();
        if (WatchdogService.ACTION_TEST_RESTART.equals(action)) {
            service.setAction(action);
        }
        context.startForegroundService(service);
    }
}
