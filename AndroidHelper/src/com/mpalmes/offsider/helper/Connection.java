package com.mpalmes.offsider.helper;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.UiAutomation;
import android.os.Build;
import android.os.HandlerThread;
import android.os.Looper;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.concurrent.TimeoutException;

/**
 * Owns one UiAutomation connection. Hidden members, all by reflection:
 * UiAutomationConnection(), UiAutomation(Looper, IUiAutomationConnection), connect(int), disconnect().
 */
final class Connection {
    private final HandlerThread thread = new HandlerThread("OffsiderHelper");
    private UiAutomation automation;
    private volatile boolean connected;
    private boolean configured;
    private boolean includesNotImportant;
    int serviceFlags;
    boolean dontSuppress;

    UiAutomation automation() {
        return automation;
    }

    void open() throws HelperFailure {
        thread.start();
        Looper looper = thread.getLooper();
        Object bridge;
        Constructor<UiAutomation> ctor;
        try {
            Class<?> bridgeClass = Class.forName("android.app.UiAutomationConnection");
            Class<?> bridgeInterface = Class.forName("android.app.IUiAutomationConnection");
            bridge = bridgeClass.getDeclaredConstructor().newInstance();
            ctor = UiAutomation.class.getDeclaredConstructor(Looper.class, bridgeInterface);
        } catch (ClassNotFoundException | NoSuchMethodException | IllegalAccessException
                | InstantiationException e) {
            throw HelperFailure.hiddenApi("UiAutomationConnection is not reachable", e);
        } catch (InvocationTargetException e) {
            throw HelperFailure.connect("UiAutomationConnection() threw", e);
        }
        try {
            automation = ctor.newInstance(looper, bridge);
        } catch (IllegalAccessException | InstantiationException e) {
            throw HelperFailure.hiddenApi("UiAutomation(Looper, IUiAutomationConnection) is not reachable", e);
        } catch (InvocationTargetException e) {
            throw HelperFailure.connect("UiAutomation(Looper, IUiAutomationConnection) threw", e);
        }
        connect();
    }

    private void connect() throws HelperFailure {
        Method withFlags = null;
        Method plain = null;
        try {
            withFlags = UiAutomation.class.getMethod("connect", int.class);
        } catch (NoSuchMethodException e) {
            try {
                plain = UiAutomation.class.getMethod("connect");
            } catch (NoSuchMethodException e2) {
                throw HelperFailure.hiddenApi("UiAutomation.connect is missing", e2);
            }
        }
        try {
            if (withFlags != null) {
                withFlags.invoke(automation, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
                dontSuppress = true;
            } else {
                plain.invoke(automation);
            }
        } catch (IllegalAccessException e) {
            throw HelperFailure.hiddenApi("UiAutomation.connect is blocked", e);
        } catch (InvocationTargetException e) {
            throw HelperFailure.fromConnect(e);
        } catch (RuntimeException e) {
            throw HelperFailure.fromConnect(e);
        }
        connected = true;
    }

    /** Requests interactive windows and view ids; calls setServiceInfo only when the flags change. */
    void configure(boolean includeNotImportant) throws HelperFailure {
        if (configured && includesNotImportant == includeNotImportant) {
            return;
        }
        try {
            AccessibilityServiceInfo info = automation.getServiceInfo();
            if (info == null) {
                throw HelperFailure.connect("UiAutomation has no service info after connect", null);
            }
            info.flags |= AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
                    | AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS;
            if (includeNotImportant) {
                info.flags |= AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS;
            } else {
                info.flags &= ~AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS;
            }
            automation.setServiceInfo(info);
            serviceFlags = info.flags;
            configured = true;
            includesNotImportant = includeNotImportant;
        } catch (RuntimeException e) {
            throw HelperFailure.connect("could not configure the UiAutomation service", e);
        }
    }

    /** Drops cached nodes so the next read sees the screen as it is now. */
    void clearCache() {
        if (Build.VERSION.SDK_INT >= 34) {
            automation.clearCache();
        } else {
            automation.setServiceInfo(automation.getServiceInfo());
        }
    }

    /** False when the screen kept changing until the timeout. */
    boolean waitForIdle(long quietMs, long timeoutMs) {
        try {
            automation.waitForIdle(quietMs, timeoutMs);
            return true;
        } catch (TimeoutException e) {
            return false;
        }
    }

    void listen(EventLog log) {
        automation.setOnAccessibilityEventListener(log);
    }

    /** Disconnects and stops the looper thread. Never throws; returns a failure detail or null. */
    synchronized String close() {
        String problem = null;
        if (connected) {
            connected = false;
            try {
                UiAutomation.class.getMethod("disconnect").invoke(automation);
            } catch (ReflectiveOperationException | RuntimeException e) {
                problem = HelperFailure.describe(e);
            }
        }
        thread.quitSafely();
        return problem;
    }
}
