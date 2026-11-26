package dev.apkinmacos.bridge;

import android.content.Context;
import android.content.ContextWrapper;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Looper;
import android.os.Process;

import java.lang.reflect.Method;

public final class BridgeMain {
    private static final String DEFAULT_SOCKET = "apkinmacos_bridge";

    public static void main(String[] args) {
        String socketName = (args.length > 0 && args[0] != null && !args[0].isEmpty())
                ? args[0]
                : DEFAULT_SOCKET;

        try { Looper.prepareMainLooper(); } catch (Throwable ignored) {}

        Context systemContext = buildSystemContext();
        EventInjector injector = new EventInjector(systemContext);

        Thread server = new Thread(() -> listen(socketName, systemContext, injector), "BridgeAccept");
        server.setDaemon(false);
        server.start();

        System.out.println("[BridgeMain] Ready on localabstract:" + socketName + " uid=" + Process.myUid());
        System.out.flush();

        Looper.loop();
    }

    private static void listen(String socketName, Context ctx, EventInjector injector) {
        try (LocalServerSocket server = new LocalServerSocket(socketName)) {
            while (true) {
                LocalSocket client = server.accept();
                Thread t = new Thread(() -> {
                    try {
                        new DisplayChannel(client, ctx, injector).serve();
                    } catch (Throwable e) {
                        System.err.println("[BridgeMain] Channel error: " + e);
                        try { client.close(); } catch (Throwable ignored) {}
                    }
                }, "DisplayChannel");
                t.setDaemon(true);
                t.start();
            }
        } catch (Throwable t) {
            System.err.println("[BridgeMain] Fatal: " + t);
            System.exit(1);
        }
    }

    private static Context buildSystemContext() {
        try {
            Class<?> atCls = Class.forName("android.app.ActivityThread");
            Object at = atCls.getMethod("systemMain").invoke(null);
            Context base = (Context) atCls.getMethod("getSystemContext").invoke(at);
            final String pkg = (Process.myUid() == 0) ? "android" : "com.android.shell";
            return new ContextWrapper(base) {
                @Override public String getPackageName() { return pkg; }
                @Override public String getOpPackageName() { return pkg; }
                @Override public Context getApplicationContext() { return this; }
            };
        } catch (Throwable t) {
            System.err.println("[BridgeMain] SystemContext init failed: " + t);
            return null;
        }
    }
}
