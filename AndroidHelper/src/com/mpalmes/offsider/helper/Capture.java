package com.mpalmes.offsider.helper;

import android.app.UiAutomation;
import android.graphics.Bitmap;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import org.json.JSONObject;

/** Display 0 through UiAutomation.takeScreenshot, as RGBA bytes in memory order, PNG or JPEG. */
final class Capture {
    private Capture() {
    }

    /** Writes the frame header and timings, and returns the frame the server sends after the reply. */
    static byte[] run(Json json, UiAutomation automation, JSONObject request) throws RequestFailure {
        String format = Requests.string(request, "format", false);
        if (format == null) {
            format = "png";
        }
        if (!"raw".equals(format) && !"png".equals(format) && !"jpeg".equals(format)) {
            throw RequestFailure.badRequest("format must be raw, png or jpeg");
        }
        int quality = (int) Requests.whole(request, "quality", 90, 1, 100);

        long start = System.nanoTime();
        Bitmap shot = automation.takeScreenshot();
        if (shot == null) {
            throw new RequestFailure("capture-failed", "UiAutomation returned no screenshot", null);
        }
        long captured = System.nanoTime();
        Bitmap bitmap = shot;
        if (shot.getConfig() != Bitmap.Config.ARGB_8888) {
            bitmap = shot.copy(Bitmap.Config.ARGB_8888, false);
            shot.recycle();
            if (bitmap == null) {
                throw new RequestFailure("capture-failed", "the screenshot could not be copied to ARGB_8888", null);
            }
        }
        long copied = System.nanoTime();
        int width = bitmap.getWidth();
        int height = bitmap.getHeight();
        byte[] frame;
        String encoding;
        try {
            if ("raw".equals(format)) {
                frame = pixels(bitmap);
                encoding = "rgba8888";
            } else {
                frame = compress(bitmap, "png".equals(format) ? Bitmap.CompressFormat.PNG : Bitmap.CompressFormat.JPEG, quality);
                encoding = format;
            }
        } finally {
            bitmap.recycle();
        }
        long encoded = System.nanoTime();
        json.name("frame").beginObject();
        json.field("width", width);
        json.field("height", height);
        json.field("format", encoding);
        json.field("bytes", frame.length);
        json.endObject();
        json.field("captureMs", ms(captured - start));
        json.field("copyMs", ms(copied - captured));
        json.field("encodeMs", ms(encoded - copied));
        return frame;
    }

    /** Tightly packed rows, four bytes a pixel. */
    private static byte[] pixels(Bitmap bitmap) throws RequestFailure {
        int width = bitmap.getWidth();
        int height = bitmap.getHeight();
        int stride = bitmap.getRowBytes();
        long packed = (long) width * height * 4;
        long total = (long) stride * height;
        if (packed > Frames.MAX_BYTES || total > Integer.MAX_VALUE) {
            throw tooLarge(packed);
        }
        ByteBuffer buffer = ByteBuffer.allocate((int) total);
        bitmap.copyPixelsToBuffer(buffer);
        byte[] bytes = buffer.array();
        if (stride == width * 4) {
            return bytes;
        }
        byte[] rows = new byte[(int) packed];
        for (int row = 0; row < height; row++) {
            System.arraycopy(bytes, row * stride, rows, row * width * 4, width * 4);
        }
        return rows;
    }

    private static byte[] compress(Bitmap bitmap, Bitmap.CompressFormat format, int quality) throws RequestFailure {
        ByteArrayOutputStream out = new ByteArrayOutputStream(1 << 20);
        if (!bitmap.compress(format, quality, out)) {
            throw new RequestFailure("capture-failed", "the screenshot could not be encoded as " + format, null);
        }
        if (out.size() > Frames.MAX_BYTES) {
            throw tooLarge(out.size());
        }
        return out.toByteArray();
    }

    private static RequestFailure tooLarge(long bytes) {
        return new RequestFailure("frame-too-large", "the screenshot needs " + bytes + " bytes, more than the "
                + Frames.MAX_BYTES + " byte frame limit", null);
    }

    private static long ms(long nanos) {
        return nanos / 1000000L;
    }
}
