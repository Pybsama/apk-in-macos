package dev.apkinmacos.bridge;

import android.content.Context;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.hardware.display.VirtualDisplayConfig;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.net.LocalSocket;
import android.os.Bundle;
import android.view.Display;
import android.view.Surface;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public final class DisplayChannel {
    private static final AtomicInteger NEXT_ID = new AtomicInteger(1);

    private static final int FLAG_SUPPORTS_TOUCH = 1 << 6;
    private static final int FLAG_ROTATES_WITH_CONTENT = 1 << 7;
    private static final int FLAG_DESTROY_CONTENT_ON_REMOVAL = 1 << 8;
    private static final int FLAG_TRUSTED = 1 << 10;
    private static final int FLAG_OWN_DISPLAY_GROUP = 1 << 11;
    private static final int FLAG_ALWAYS_UNLOCKED = 1 << 12;
    private static final int FLAG_OWN_FOCUS = 1 << 14;

    private final int channelId = NEXT_ID.getAndIncrement();
    private final LocalSocket socket;
    private final Context context;
    private final EventInjector injector;
    private final DataInputStream in;
    private final DataOutputStream out;
    private final Object sendLock = new Object();
    private final Object mediaLock = new Object();
    private final AtomicBoolean active = new AtomicBoolean(true);

    private byte mode;
    private volatile int width;
    private volatile int height;
    private volatile int dpi;
    private int bitrate;
    private int fps;
    private volatile int displayId = -1;

    private VirtualDisplay virtualDisplay;
    private MediaCodec encoder;
    private Surface encoderSurface;

    public DisplayChannel(LocalSocket socket, Context context, EventInjector injector) throws IOException {
        this.socket = socket;
        this.context = context;
        this.injector = injector;
        this.in = new DataInputStream(new BufferedInputStream(socket.getInputStream()));
        this.out = new DataOutputStream(new BufferedOutputStream(socket.getOutputStream()));
    }

    public void serve() {
        try {
            if (in.readInt() != WireProtocol.MAGIC) {
                sendError("Invalid bridge magic");
                return;
            }
            byte ver = in.readByte();
            if (ver != WireProtocol.VERSION) {
                sendError("Unsupported protocol version: " + ver);
                return;
            }

            this.mode = in.readByte();
            this.width = align16(clamp(in.readInt(), 240, 2560));
            this.height = align16(clamp(in.readInt(), 240, 2560));
            this.dpi = clamp(in.readInt(), 120, 640);
            this.bitrate = clamp(in.readInt(), 1_000_000, 24_000_000);
            this.fps = clamp(in.readInt(), 15, 60);

            openDisplayAndEncoder();
            sendReady(displayId, width, height);
            commandLoop();
        } catch (EOFException ignored) {
            // Normal client close
        } catch (Throwable t) {
            System.err.println("[Channel " + channelId + "] Error: " + t);
            try { sendError(t.getClass().getSimpleName() + ": " + t.getMessage()); } catch (Throwable ignored) {}
        } finally {
            teardown();
        }
    }

    private void openDisplayAndEncoder() throws Exception {
        synchronized (mediaLock) {
            createEncoder(width, height);
            if (mode == WireProtocol.MODE_MAIN_MIRROR) {
                virtualDisplay = createMirror("ShelfMain-" + channelId, width, height, 0, encoderSurface);
                displayId = 0;
            } else {
                virtualDisplay = createIsolatedDisplay("ShelfWin-" + channelId, width, height, dpi, encoderSurface);
                Display d = virtualDisplay.getDisplay();
                if (d == null) throw new IllegalStateException("VirtualDisplay returned null Display");
                displayId = d.getDisplayId();
            }
            spawnDrainThreadLocked();
        }
        System.out.println("[Channel " + channelId + "] Ready displayId=" + displayId + " " + width + "x" + height + " @" + dpi + "dpi");
    }

    private void createEncoder(int w, int h) throws IOException {
        MediaFormat fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h);
        fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        fmt.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
        fmt.setInteger(MediaFormat.KEY_FRAME_RATE, fps);
        fmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2);
        fmt.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 180_000L);
        fmt.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0);

        MediaCodec codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        codec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        Surface surface = codec.createInputSurface();
        codec.start();

        this.encoder = codec;
        this.encoderSurface = surface;
    }

    private VirtualDisplay createIsolatedDisplay(String name, int w, int h, int density, Surface surface) throws Exception {
        DisplayManager dm = (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
        if (dm == null) throw new IllegalStateException("DisplayManager unavailable");

        int fullFlags = DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC
                | DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY
                | FLAG_SUPPORTS_TOUCH
                | FLAG_ROTATES_WITH_CONTENT
                | FLAG_DESTROY_CONTENT_ON_REMOVAL
                | FLAG_TRUSTED
                | FLAG_OWN_DISPLAY_GROUP
                | FLAG_ALWAYS_UNLOCKED
                | FLAG_OWN_FOCUS;

        try {
            VirtualDisplayConfig cfg = new VirtualDisplayConfig.Builder(name, w, h, density)
                    .setSurface(surface)
                    .setFlags(fullFlags)
                    .build();
            VirtualDisplay vd = dm.createVirtualDisplay(cfg);
            if (vd != null) return vd;
        } catch (SecurityException se) {
            System.err.println("[Channel " + channelId + "] Trusted flags denied, using fallback flags: " + se.getMessage());
        }

        int basicFlags = DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC
                | DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY
                | FLAG_SUPPORTS_TOUCH
                | FLAG_ROTATES_WITH_CONTENT
                | FLAG_DESTROY_CONTENT_ON_REMOVAL;

        VirtualDisplayConfig fallback = new VirtualDisplayConfig.Builder(name, w, h, density)
                .setSurface(surface)
                .setFlags(basicFlags)
                .build();
        VirtualDisplay vd = dm.createVirtualDisplay(fallback);
        if (vd == null) throw new IllegalStateException("createVirtualDisplay returned null");
        return vd;
    }

    private VirtualDisplay createMirror(String name, int w, int h, int mirrorId, Surface surface) throws Exception {
        Method m = DisplayManager.class.getMethod("createVirtualDisplay", String.class, int.class, int.class, int.class, Surface.class);
        VirtualDisplay vd = (VirtualDisplay) m.invoke(null, name, w, h, mirrorId, surface);
        if (vd == null) throw new IllegalStateException("Mirror virtual display returned null");
        return vd;
    }

    private void spawnDrainThreadLocked() {
        final MediaCodec boundCodec = this.encoder;
        Thread t = new Thread(() -> drainEncoder(boundCodec), "Drain-" + channelId);
        t.setDaemon(true);
        t.start();
    }

    private void drainEncoder(MediaCodec boundCodec) {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        while (active.get()) {
            MediaCodec current;
            synchronized (mediaLock) {
                current = this.encoder;
            }
            if (current != boundCodec) return;
            try {
                int idx = boundCodec.dequeueOutputBuffer(info, 50_000);
                if (idx >= 0) {
                    try {
                        ByteBuffer buf = boundCodec.getOutputBuffer(idx);
                        if (buf != null && info.size > 0) {
                            buf.position(info.offset);
                            buf.limit(info.offset + info.size);
                            byte[] bytes = new byte[info.size];
                            buf.get(bytes);
                            if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                                sendPacket(WireProtocol.PKT_CODEC_CONFIG, bytes);
                            } else {
                                boolean keyframe = (info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0;
                                sendFrame(keyframe ? 1 : 0, info.presentationTimeUs, bytes);
                            }
                        }
                    } finally {
                        boundCodec.releaseOutputBuffer(idx, false);
                    }
                } else if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat fmt = boundCodec.getOutputFormat();
                    ByteBuffer csd0 = fmt.getByteBuffer("csd-0");
                    ByteBuffer csd1 = fmt.getByteBuffer("csd-1");
                    if (csd0 != null) {
                        int n0 = csd0.remaining();
                        int n1 = (csd1 != null) ? csd1.remaining() : 0;
                        byte[] cfg = new byte[n0 + n1];
                        csd0.duplicate().get(cfg, 0, n0);
                        if (csd1 != null) csd1.duplicate().get(cfg, n0, n1);
                        sendPacket(WireProtocol.PKT_CODEC_CONFIG, cfg);
                    }
                }
            } catch (IllegalStateException ise) {
                return;
            } catch (IOException ioe) {
                active.set(false);
                return;
            } catch (Throwable t) {
                System.err.println("[Channel " + channelId + "] drain error: " + t);
                return;
            }
        }
    }

    private void resizeDisplay(int newW, int newH, int newDpi) {
        int aw = align16(clamp(newW, 240, 2560));
        int ah = align16(clamp(newH, 240, 2560));
        int cdpi = clamp(newDpi, 120, 640);
        if (aw == width && ah == height && cdpi == dpi) return;

        synchronized (mediaLock) {
            MediaCodec oldCodec = this.encoder;
            Surface oldSurface = this.encoderSurface;
            try {
                createEncoder(aw, ah);
                this.width = aw;
                this.height = ah;
                this.dpi = cdpi;
                if (virtualDisplay != null) {
                    virtualDisplay.setSurface(this.encoderSurface);
                    virtualDisplay.resize(aw, ah, cdpi);
                }
                spawnDrainThreadLocked();
                sendResized(aw, ah);
            } catch (Throwable t) {
                System.err.println("[Channel " + channelId + "] resize failed: " + t);
                return;
            } finally {
                if (oldCodec != null) {
                    try { oldCodec.stop(); } catch (Throwable ignored) {}
                    try { oldCodec.release(); } catch (Throwable ignored) {}
                }
                if (oldSurface != null) {
                    try { oldSurface.release(); } catch (Throwable ignored) {}
                }
            }
        }
    }

    private void commandLoop() throws IOException {
        while (active.get()) {
            byte cmd = in.readByte();
            int len = in.readInt();
            if (len < 0 || len > 1024 * 1024) throw new IOException("Bad command len: " + len);
            byte[] payload = (len > 0) ? new byte[len] : new byte[0];
            if (len > 0) in.readFully(payload);
            ByteBuffer bb = ByteBuffer.wrap(payload);

            switch (cmd) {
                case WireProtocol.CMD_TOUCH:
                    if (len >= 13) {
                        int action = bb.get() & 0xFF;
                        int pid = bb.getInt();
                        float nx = bb.getFloat();
                        float ny = bb.getFloat();
                        float px = Math.max(0f, Math.min(width - 1f, nx * width));
                        float py = Math.max(0f, Math.min(height - 1f, ny * height));
                        injector.touch(displayId, action, pid, px, py);
                    }
                    break;
                case WireProtocol.CMD_SCROLL:
                    if (len >= 16) {
                        float nx = bb.getFloat();
                        float ny = bb.getFloat();
                        float hs = bb.getFloat();
                        float vs = bb.getFloat();
                        float px = Math.max(0f, Math.min(width - 1f, nx * width));
                        float py = Math.max(0f, Math.min(height - 1f, ny * height));
                        injector.scroll(displayId, px, py, hs, vs);
                    }
                    break;
                case WireProtocol.CMD_KEY:
                    if (len >= 9) {
                        int action = bb.get() & 0xFF;
                        int kc = bb.getInt();
                        int meta = bb.getInt();
                        injector.key(displayId, action, kc, meta);
                    }
                    break;
                case WireProtocol.CMD_TEXT:
                    injector.text(displayId, new String(payload, StandardCharsets.UTF_8));
                    break;
                case WireProtocol.CMD_RESIZE:
                    if (len >= 12) {
                        resizeDisplay(bb.getInt(), bb.getInt(), bb.getInt());
                    }
                    break;
                case WireProtocol.CMD_SYNC_FRAME:
                    synchronized (mediaLock) {
                        if (encoder != null) {
                            try {
                                Bundle b = new Bundle();
                                b.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
                                encoder.setParameters(b);
                            } catch (Throwable ignored) {}
                        }
                    }
                    break;
                case WireProtocol.CMD_CLIPBOARD:
                    if (len >= 1) {
                        boolean paste = payload[0] != 0;
                        String text = new String(payload, 1, len - 1, StandardCharsets.UTF_8);
                        injector.clipboard(displayId, text, paste);
                    }
                    break;
                case WireProtocol.CMD_CLOSE:
                    active.set(false);
                    return;
                default:
                    break;
            }
        }
    }

    private void sendReady(int dId, int w, int h) throws IOException {
        ByteBuffer bb = ByteBuffer.allocate(12);
        bb.putInt(dId).putInt(w).putInt(h);
        sendPacket(WireProtocol.PKT_READY, bb.array());
    }

    private void sendResized(int w, int h) throws IOException {
        ByteBuffer bb = ByteBuffer.allocate(8);
        bb.putInt(w).putInt(h);
        sendPacket(WireProtocol.PKT_RESIZED, bb.array());
    }

    private void sendFrame(int flags, long ptsUs, byte[] frame) throws IOException {
        synchronized (sendLock) {
            out.writeByte(WireProtocol.PKT_VIDEO_FRAME);
            out.writeInt(12 + frame.length);
            out.writeInt(flags);
            out.writeLong(ptsUs);
            out.write(frame);
            out.flush();
        }
    }

    private void sendError(String message) throws IOException {
        sendPacket(WireProtocol.PKT_ERROR, (message != null ? message : "Error").getBytes(StandardCharsets.UTF_8));
    }

    private void sendPacket(byte type, byte[] payload) throws IOException {
        synchronized (sendLock) {
            out.writeByte(type);
            out.writeInt(payload.length);
            if (payload.length > 0) out.write(payload);
            out.flush();
        }
    }

    private void teardown() {
        active.set(false);
        synchronized (mediaLock) {
            if (virtualDisplay != null) {
                try { virtualDisplay.release(); } catch (Throwable ignored) {}
                virtualDisplay = null;
            }
            if (encoder != null) {
                try { encoder.stop(); } catch (Throwable ignored) {}
                try { encoder.release(); } catch (Throwable ignored) {}
                encoder = null;
            }
            if (encoderSurface != null) {
                try { encoderSurface.release(); } catch (Throwable ignored) {}
                encoderSurface = null;
            }
        }
        try { socket.close(); } catch (Throwable ignored) {}
    }

    private static int align16(int v) { return Math.max(16, (v + 8) & ~15); }
    private static int clamp(int v, int lo, int hi) { return Math.max(lo, Math.min(hi, v)); }
}
