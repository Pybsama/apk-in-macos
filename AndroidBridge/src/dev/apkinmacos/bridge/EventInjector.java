package dev.apkinmacos.bridge;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.IBinder;
import android.os.IInterface;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.lang.reflect.Method;

public final class EventInjector {
    private static final int MODE_ASYNC = 0;

    private final Context context;
    private final Object inputManager;
    private final Method injectMethod;
    private final Method setDisplayIdMethod;
    private final KeyCharacterMap virtualKcm;

    private long pointerDownTime = 0;

    public EventInjector(Context context) {
        this.context = context;
        this.virtualKcm = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD);

        Object im = null;
        Method inject = null;
        try {
            Class<?> cls = Class.forName("android.hardware.input.InputManagerGlobal");
            im = cls.getMethod("getInstance").invoke(null);
            inject = cls.getMethod("injectInputEvent", InputEvent.class, int.class);
        } catch (Throwable t1) {
            try {
                Class<?> cls = Class.forName("android.hardware.input.InputManager");
                im = cls.getMethod("getInstance").invoke(null);
                inject = cls.getMethod("injectInputEvent", InputEvent.class, int.class);
            } catch (Throwable t2) {
                System.err.println("[EventInjector] InputManager unavailable: " + t2);
            }
        }
        this.inputManager = im;
        this.injectMethod = inject;

        Method mDisplayId = null;
        try {
            mDisplayId = InputEvent.class.getMethod("setDisplayId", int.class);
        } catch (Throwable ignored) {}
        this.setDisplayIdMethod = mDisplayId;
    }

    private void dispatch(InputEvent event, int displayId) {
        if (inputManager == null || injectMethod == null) return;
        try {
            if (setDisplayIdMethod != null) {
                setDisplayIdMethod.invoke(event, displayId);
            }
            injectMethod.invoke(inputManager, event, MODE_ASYNC);
        } catch (Throwable t) {
            System.err.println("[EventInjector] dispatch failed on display " + displayId + ": " + t);
        }
    }

    public synchronized void touch(int displayId, int action, int pointerId, float x, float y) {
        long now = SystemClock.uptimeMillis();
        int masked;
        float pressure = 1.0f;
        switch (action) {
            case 0:
                pointerDownTime = now;
                masked = MotionEvent.ACTION_DOWN;
                break;
            case 1:
                masked = MotionEvent.ACTION_UP;
                pressure = 0.0f;
                break;
            case 2:
                masked = MotionEvent.ACTION_MOVE;
                break;
            default:
                masked = MotionEvent.ACTION_CANCEL;
                pressure = 0.0f;
                break;
        }
        if (pointerDownTime == 0) pointerDownTime = now;

        MotionEvent.PointerProperties[] props = { new MotionEvent.PointerProperties() };
        props[0].id = pointerId;
        props[0].toolType = MotionEvent.TOOL_TYPE_FINGER;

        MotionEvent.PointerCoords[] coords = { new MotionEvent.PointerCoords() };
        coords[0].x = x;
        coords[0].y = y;
        coords[0].pressure = pressure;
        coords[0].size = 1.0f;

        MotionEvent ev = MotionEvent.obtain(
                pointerDownTime, now, masked, 1, props, coords,
                0, 0, 1.0f, 1.0f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0
        );
        try {
            dispatch(ev, displayId);
        } finally {
            ev.recycle();
        }
    }

    public synchronized void scroll(int displayId, float x, float y, float hScroll, float vScroll) {
        long now = SystemClock.uptimeMillis();
        MotionEvent.PointerProperties[] props = { new MotionEvent.PointerProperties() };
        props[0].id = 0;
        props[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;

        MotionEvent.PointerCoords[] coords = { new MotionEvent.PointerCoords() };
        coords[0].x = x;
        coords[0].y = y;
        coords[0].setAxisValue(MotionEvent.AXIS_HSCROLL, hScroll);
        coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, vScroll);

        MotionEvent ev = MotionEvent.obtain(
                now, now, MotionEvent.ACTION_SCROLL, 1, props, coords,
                0, 0, 1.0f, 1.0f, 0, 0, InputDevice.SOURCE_MOUSE, 0
        );
        try {
            dispatch(ev, displayId);
        } finally {
            ev.recycle();
        }
    }

    public synchronized void key(int displayId, int action, int keyCode, int metaState) {
        long now = SystemClock.uptimeMillis();
        int ka = (action == 0) ? KeyEvent.ACTION_DOWN : KeyEvent.ACTION_UP;
        KeyEvent ev = new KeyEvent(
                now, now, ka, keyCode, 0, metaState,
                KeyCharacterMap.VIRTUAL_KEYBOARD, 0,
                KeyEvent.FLAG_FROM_SYSTEM, InputDevice.SOURCE_KEYBOARD
        );
        dispatch(ev, displayId);
    }

    public synchronized void text(int displayId, String content) {
        if (content == null || content.isEmpty()) return;
        boolean pureAscii = true;
        for (int i = 0; i < content.length(); i++) {
            char c = content.charAt(i);
            if (c < 0x20 || c > 0x7E) {
                pureAscii = false;
                break;
            }
        }
        if (pureAscii) {
            KeyEvent[] events = virtualKcm.getEvents(content.toCharArray());
            if (events != null) {
                for (KeyEvent e : events) {
                    dispatch(e, displayId);
                }
                return;
            }
        }
        clipboard(displayId, content, true);
    }

    public synchronized void clipboard(int displayId, String content, boolean pasteNow) {
        if (content == null) return;
        writeClipboard(content);
        if (pasteNow) {
            key(displayId, 0, KeyEvent.KEYCODE_PASTE, 0);
            key(displayId, 1, KeyEvent.KEYCODE_PASTE, 0);
        }
    }

    private void writeClipboard(String content) {
        try {
            if (context != null) {
                ClipboardManager cm = (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
                if (cm != null) {
                    cm.setPrimaryClip(ClipData.newPlainText("macOS", content));
                    return;
                }
            }
        } catch (Throwable ignored) {}

        try {
            Class<?> smClass = Class.forName("android.os.ServiceManager");
            IBinder binder = (IBinder) smClass.getMethod("getService", String.class).invoke(null, "clipboard");
            Class<?> stub = Class.forName("android.content.IClipboard$Stub");
            IInterface svc = (IInterface) stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
            ClipData clip = ClipData.newPlainText("macOS", content);
            String pkg = (android.os.Process.myUid() == 0) ? "android" : "com.android.shell";
            for (Method m : svc.getClass().getMethods()) {
                if (!"setPrimaryClip".equals(m.getName())) continue;
                int n = m.getParameterTypes().length;
                if (n == 5) { m.invoke(svc, clip, pkg, null, 0, 0); return; }
                if (n == 4) { m.invoke(svc, clip, pkg, null, 0); return; }
                if (n == 3) { m.invoke(svc, clip, pkg, 0); return; }
            }
        } catch (Throwable t) {
            System.err.println("[EventInjector] clipboard write failed: " + t);
        }
    }
}
