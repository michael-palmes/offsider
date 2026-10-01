package com.mpalmes.offsider.helper;

import android.app.UiAutomation;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityEvent;
import java.util.ArrayList;
import java.util.List;

/** The latest relevant accessibility events, numbered from 1, so a verifier can wake between tree reads. */
final class EventLog implements UiAutomation.OnAccessibilityEventListener {
    static final String SYSTEM_UI = "com.android.systemui";
    static final int MAX_REPLY = 64;

    static final class Entry {
        final long seq;
        final int type;
        final String pkg;
        final int windowId;

        Entry(long seq, int type, String pkg, int windowId) {
            this.seq = seq;
            this.type = type;
            this.pkg = pkg;
            this.windowId = windowId;
        }
    }

    private final Entry[] ring;
    private long seq;

    EventLog(int capacity) {
        ring = new Entry[capacity];
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        int type = event.getEventType();
        CharSequence pkg = event.getPackageName();
        if (relevant(type, pkg)) {
            record(type, pkg == null ? null : pkg.toString(), event.getWindowId());
        }
    }

    /** Window changes from anywhere; view changes except the status bar's clock, battery and icons. */
    static boolean relevant(int type, CharSequence pkg) {
        switch (type) {
            case AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED:
            case AccessibilityEvent.TYPE_WINDOWS_CHANGED:
                return true;
            case AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED:
            case AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED:
            case AccessibilityEvent.TYPE_VIEW_SELECTED:
            case AccessibilityEvent.TYPE_VIEW_FOCUSED:
            case AccessibilityEvent.TYPE_VIEW_SCROLLED:
            case AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED:
            case AccessibilityEvent.TYPE_VIEW_CLICKED:
            case AccessibilityEvent.TYPE_VIEW_LONG_CLICKED:
                return pkg == null || !SYSTEM_UI.contentEquals(pkg);
            default:
                return false;
        }
    }

    synchronized void record(int type, String pkg, int windowId) {
        seq++;
        ring[(int) (seq % ring.length)] = new Entry(seq, type, pkg, windowId);
        notifyAll();
    }

    synchronized long latest() {
        return seq;
    }

    /** Events after since, oldest first and at most MAX_REPLY, waiting up to waitMs for the first. */
    synchronized List<Entry> await(long since, long waitMs) throws InterruptedException {
        long from = Math.min(Math.max(since, 0), seq);
        long deadline = SystemClock.uptimeMillis() + waitMs;
        while (seq <= from) {
            long left = deadline - SystemClock.uptimeMillis();
            if (left <= 0) {
                break;
            }
            wait(left);
        }
        List<Entry> out = new ArrayList<Entry>();
        long first = Math.max(from + 1, seq - ring.length + 1);
        for (long s = first; s <= seq && out.size() < MAX_REPLY; s++) {
            out.add(ring[(int) (s % ring.length)]);
        }
        return out;
    }
}
