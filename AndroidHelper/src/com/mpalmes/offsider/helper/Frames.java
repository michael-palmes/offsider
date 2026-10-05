package com.mpalmes.offsider.helper;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** Length-prefixed frames: a 4-byte big-endian length, then that many bytes of UTF-8 JSON or a screenshot. */
final class Frames {
    static final int MAX_BYTES = 32 << 20;

    private Frames() {
    }

    /** One payload, or null when the stream ends cleanly before a frame starts. */
    static byte[] read(InputStream in) throws IOException {
        byte[] header = new byte[4];
        int got = fill(in, header);
        if (got == 0) {
            return null;
        }
        if (got < header.length) {
            throw new EOFException("the connection closed inside a frame header");
        }
        long length = ((header[0] & 0xffL) << 24) | ((header[1] & 0xff) << 16)
                | ((header[2] & 0xff) << 8) | (header[3] & 0xff);
        if (length > MAX_BYTES) {
            throw new IOException("a frame of " + length + " bytes is over the " + MAX_BYTES + " byte limit");
        }
        byte[] payload = new byte[(int) length];
        if (fill(in, payload) < payload.length) {
            throw new EOFException("the connection closed inside a frame");
        }
        return payload;
    }

    static void write(OutputStream out, byte[] payload) throws IOException {
        if (payload.length > MAX_BYTES) {
            throw new IOException("a reply of " + payload.length + " bytes is over the " + MAX_BYTES + " byte limit");
        }
        byte[] header = {
            (byte) (payload.length >>> 24), (byte) (payload.length >>> 16), (byte) (payload.length >>> 8), (byte) payload.length,
        };
        out.write(header);
        out.write(payload);
        out.flush();
    }

    private static int fill(InputStream in, byte[] buffer) throws IOException {
        int total = 0;
        while (total < buffer.length) {
            int n = in.read(buffer, total, buffer.length - total);
            if (n < 0) {
                break;
            }
            total += n;
        }
        return total;
    }
}
