package dev.apkinmacos.bridge;

public final class WireProtocol {
    public static final int MAGIC = 0x414D4353; // "AMCS"
    public static final byte VERSION = 1;

    public static final byte MODE_VIRTUAL = 1;
    public static final byte MODE_MAIN_MIRROR = 2;

    // Server -> Host
    public static final byte PKT_READY = 0x01;
    public static final byte PKT_CODEC_CONFIG = 0x02;
    public static final byte PKT_VIDEO_FRAME = 0x03;
    public static final byte PKT_RESIZED = 0x04;
    public static final byte PKT_ERROR = 0x05;

    // Host -> Server
    public static final byte CMD_TOUCH = 0x10;
    public static final byte CMD_SCROLL = 0x11;
    public static final byte CMD_KEY = 0x12;
    public static final byte CMD_TEXT = 0x13;
    public static final byte CMD_RESIZE = 0x14;
    public static final byte CMD_SYNC_FRAME = 0x15;
    public static final byte CMD_CLIPBOARD = 0x16;
    public static final byte CMD_CLOSE = 0x17;

    private WireProtocol() {}
}
