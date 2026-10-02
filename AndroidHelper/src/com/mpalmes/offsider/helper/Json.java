package com.mpalmes.offsider.helper;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Minimal streaming JSON writer: compact output, comma tracking, strict string escaping. */
final class Json {
    private final StringBuilder out = new StringBuilder(64 * 1024);
    private boolean[] needComma = new boolean[64];
    private int depth;
    private boolean afterName;

    Json beginObject() {
        prefix();
        out.append('{');
        push();
        return this;
    }

    Json endObject() {
        depth--;
        out.append('}');
        return this;
    }

    Json beginArray() {
        prefix();
        out.append('[');
        push();
        return this;
    }

    Json endArray() {
        depth--;
        out.append(']');
        return this;
    }

    Json name(String name) {
        if (needComma[depth]) {
            out.append(',');
        }
        needComma[depth] = true;
        quote(name);
        out.append(':');
        afterName = true;
        return this;
    }

    Json value(CharSequence value) {
        prefix();
        if (value == null) {
            out.append("null");
        } else {
            quote(value);
        }
        return this;
    }

    Json value(long value) {
        prefix();
        out.append(value);
        return this;
    }

    Json value(double value) {
        prefix();
        if (Double.isNaN(value) || Double.isInfinite(value)) {
            out.append("null");
        } else if (value == Math.rint(value) && Math.abs(value) < 1e15) {
            out.append((long) value);
        } else {
            out.append(value);
        }
        return this;
    }

    /** A float in its shortest form, so a range read back as a double casts to the same float. */
    Json valueFloat(float value) {
        prefix();
        if (Float.isNaN(value) || Float.isInfinite(value)) {
            out.append("null");
        } else if (value == Math.rint(value) && Math.abs(value) < 1e15f) {
            out.append((long) value);
        } else {
            out.append(Float.toString(value));
        }
        return this;
    }

    Json value(boolean value) {
        prefix();
        out.append(value);
        return this;
    }

    Json nullValue() {
        prefix();
        out.append("null");
        return this;
    }

    Json field(String name, CharSequence value) {
        return name(name).value(value);
    }

    Json field(String name, long value) {
        return name(name).value(value);
    }

    Json field(String name, double value) {
        return name(name).value(value);
    }

    Json field(String name, boolean value) {
        return name(name).value(value);
    }

    /** Writes the field only when the value is non-null and non-empty. */
    Json optional(String name, CharSequence value) {
        if (value != null && value.length() > 0) {
            name(name).value(value);
        }
        return this;
    }

    /** Writes the field only when it is true. */
    Json flag(String name, boolean value) {
        if (value) {
            name(name).value(true);
        }
        return this;
    }

    Json bounds(String name, int left, int top, int right, int bottom) {
        name(name).beginArray();
        value(left).value(top).value(right).value(bottom);
        return endArray();
    }

    @Override
    public String toString() {
        return out.toString();
    }

    byte[] bytes() {
        return out.toString().getBytes(StandardCharsets.UTF_8);
    }

    private void prefix() {
        if (afterName) {
            afterName = false;
            return;
        }
        if (needComma[depth]) {
            out.append(',');
        }
        needComma[depth] = true;
    }

    private void push() {
        depth++;
        if (depth >= needComma.length) {
            needComma = Arrays.copyOf(needComma, needComma.length * 2);
        }
        needComma[depth] = false;
    }

    private void quote(CharSequence s) {
        out.append('"');
        int n = s.length();
        for (int i = 0; i < n; i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':
                    out.append("\\\"");
                    break;
                case '\\':
                    out.append("\\\\");
                    break;
                case '\n':
                    out.append("\\n");
                    break;
                case '\r':
                    out.append("\\r");
                    break;
                case '\t':
                    out.append("\\t");
                    break;
                case '\b':
                    out.append("\\b");
                    break;
                case '\f':
                    out.append("\\f");
                    break;
                default:
                    if (c < 0x20 || c == 0x2028 || c == 0x2029 || isLoneSurrogate(s, i, n)) {
                        unicode(c);
                    } else {
                        out.append(c);
                    }
                    break;
            }
        }
        out.append('"');
    }

    private static boolean isLoneSurrogate(CharSequence s, int i, int n) {
        char c = s.charAt(i);
        if (Character.isHighSurrogate(c)) {
            return i + 1 >= n || !Character.isLowSurrogate(s.charAt(i + 1));
        }
        if (Character.isLowSurrogate(c)) {
            return i == 0 || !Character.isHighSurrogate(s.charAt(i - 1));
        }
        return false;
    }

    private void unicode(char c) {
        String hex = Integer.toHexString(c);
        out.append("\\u");
        for (int pad = hex.length(); pad < 4; pad++) {
            out.append('0');
        }
        out.append(hex);
    }
}
