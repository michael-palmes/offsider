package com.mpalmes.offsider.helper;

import java.lang.reflect.InvocationTargetException;

/** A failure that ends the process, with a stable error code and exit status. */
final class HelperFailure extends Exception {
    private static final long serialVersionUID = 1L;

    static final int EXIT_USAGE = 2;
    static final int EXIT_HIDDEN_API = 3;
    static final int EXIT_BUSY = 4;
    static final int EXIT_CONNECT = 5;
    static final int EXIT_CRASH = 6;
    static final int EXIT_NO_CLIENT = 7;

    final int exitCode;
    final String code;
    final String detail;

    HelperFailure(int exitCode, String code, String message, Throwable cause) {
        super(message, cause);
        this.exitCode = exitCode;
        this.code = code;
        this.detail = describe(cause);
    }

    static HelperFailure usage(String message) {
        return new HelperFailure(EXIT_USAGE, "usage", message, null);
    }

    static HelperFailure hiddenApi(String message, Throwable cause) {
        return new HelperFailure(EXIT_HIDDEN_API, "hidden-api-unavailable", message, cause);
    }

    static HelperFailure connect(String message, Throwable cause) {
        return new HelperFailure(EXIT_CONNECT, "connect-failed", message, cause);
    }

    static HelperFailure crash(String code, String message, Throwable cause) {
        return new HelperFailure(EXIT_CRASH, code, message, cause);
    }

    /** Maps a failed connect to busy when another client holds the UiAutomation slot. */
    static HelperFailure fromConnect(Throwable cause) {
        for (Throwable t = unwrap(cause); t != null; t = t.getCause()) {
            String m = t.getMessage();
            if (m != null && m.contains("already registered")) {
                return new HelperFailure(EXIT_BUSY, "uiautomation-busy",
                        "another UiAutomation client is connected (Appium, Maestro, uiautomator,"
                                + " an instrumentation test or Layout Inspector)", cause);
            }
        }
        return connect("UiAutomation connect failed", cause);
    }

    static Throwable unwrap(Throwable t) {
        while (t instanceof InvocationTargetException && t.getCause() != null) {
            t = t.getCause();
        }
        return t;
    }

    /** One line: each cause as "Class: message", outermost first. */
    static String describe(Throwable cause) {
        if (cause == null) {
            return null;
        }
        StringBuilder sb = new StringBuilder();
        int guard = 0;
        for (Throwable t = unwrap(cause); t != null && guard < 8; t = t.getCause(), guard++) {
            if (sb.length() > 0) {
                sb.append(" <- ");
            }
            sb.append(t.getClass().getName());
            String m = t.getMessage();
            if (m != null) {
                int newline = m.indexOf('\n');
                sb.append(": ").append(newline < 0 ? m : m.substring(0, newline));
            }
        }
        return sb.toString();
    }
}
