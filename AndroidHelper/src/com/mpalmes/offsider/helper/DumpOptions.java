package com.mpalmes.offsider.helper;

import org.json.JSONObject;

/** What one dump reads. Requests default to what uiautomator dump --compressed shows of the app. */
final class DumpOptions {
    static final long MAX_IDLE_MS = 10000;

    boolean appWindowsOnly = true;
    boolean includeNotImportant;
    boolean visibleOnly = true;
    boolean testTags = true;
    boolean idle = true;
    long idleQuietMs = 100;
    long idleTimeoutMs = 500;
    /** The package whose recent toasts the reply lists, FRONT for the app window's own; null lists none. */
    String toasts;

    static final String FRONT = "front";
    static final int MAX_PACKAGE = 255;

    /** The one-shot dump mode's default: every window and every node, for checks by hand. */
    static DumpOptions fullTree() {
        DumpOptions o = new DumpOptions();
        o.appWindowsOnly = false;
        o.includeNotImportant = true;
        o.visibleOnly = false;
        return o;
    }

    static boolean isPackageName(String name) {
        if (name.isEmpty() || name.length() > MAX_PACKAGE || name.startsWith(".") || name.endsWith(".")) {
            return false;
        }
        for (int i = 0; i < name.length(); i++) {
            char c = name.charAt(i);
            if (!(c == '.' || c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) {
                return false;
            }
        }
        return true;
    }

    static DumpOptions from(JSONObject request) throws RequestFailure {
        DumpOptions o = new DumpOptions();
        String windows = Requests.string(request, "windows", false);
        if (windows == null || "app".equals(windows)) {
            o.appWindowsOnly = true;
        } else if ("all".equals(windows)) {
            o.appWindowsOnly = false;
        } else {
            throw RequestFailure.badRequest("windows must be app or all, got '" + windows + "'");
        }
        o.includeNotImportant = Requests.bool(request, "notImportant", false);
        o.visibleOnly = Requests.bool(request, "visibleOnly", true);
        o.testTags = Requests.bool(request, "testTags", true);
        o.idleQuietMs = Requests.whole(request, "idleQuietMs", 100, 0, MAX_IDLE_MS);
        o.idleTimeoutMs = Requests.whole(request, "idleTimeoutMs", 500, 0, MAX_IDLE_MS);
        if (o.idleQuietMs > o.idleTimeoutMs) {
            throw RequestFailure.badRequest("idleQuietMs must not exceed idleTimeoutMs");
        }
        o.idle = o.idleTimeoutMs > 0;
        o.toasts = Requests.string(request, "toasts", false);
        if (o.toasts != null && !FRONT.equals(o.toasts) && !isPackageName(o.toasts)) {
            throw RequestFailure.badRequest("toasts must be front or a package name");
        }
        return o;
    }
}
