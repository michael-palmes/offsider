package com.mpalmes.offsider.helper;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/** Recent toasts in memory only: at most CAPACITY, none older than MAX_AGE_MS, and only one package's ever leave it. */
final class ToastLog {
    static final int CAPACITY = 16;
    static final long MAX_AGE_MS = 30000;
    static final int MAX_TEXT = 500;
    static final String TOAST_CLASS = "android.widget.Toast";

    static final class Entry {
        final long seq;
        final String text;
        final String pkg;
        final long atMs;

        Entry(long seq, String text, String pkg, long atMs) {
            this.seq = seq;
            this.text = text;
            this.pkg = pkg;
            this.atMs = atMs;
        }
    }

    private final ArrayDeque<Entry> entries = new ArrayDeque<Entry>();
    private final Set<String> keep;
    private long seq;

    /** keep: the only packages whose toasts are held at all, as on a phone held to its apps; null holds every package's. */
    ToastLog(Set<String> keep) {
        this.keep = keep;
    }

    /** Android's Toast, and its inner classes on older releases. */
    static boolean isToast(CharSequence className) {
        if (className == null) {
            return false;
        }
        String name = className.toString();
        return name.equals(TOAST_CLASS) || name.startsWith(TOAST_CLASS + "$");
    }

    /** Ignores a toast with no package or no text, which could never be reported, and one from a package it does not keep. */
    synchronized void record(String text, String pkg, long nowMs) {
        if (pkg == null || pkg.isEmpty() || text == null || text.trim().isEmpty() || (keep != null && !keep.contains(pkg))) {
            return;
        }
        prune(nowMs);
        if (entries.size() >= CAPACITY) {
            entries.removeFirst();
        }
        seq++;
        String kept = text.length() > MAX_TEXT ? text.substring(0, MAX_TEXT) : text;
        entries.addLast(new Entry(seq, kept, pkg, nowMs));
    }

    /** The package's toasts, oldest first; any other package's never leave this method. */
    synchronized List<Entry> recent(String pkg, long nowMs) {
        prune(nowMs);
        List<Entry> out = new ArrayList<Entry>();
        if (pkg == null) {
            return out;
        }
        for (Entry entry : entries) {
            if (pkg.equals(entry.pkg)) {
                out.add(entry);
            }
        }
        return out;
    }

    /** Entries arrive in time order, so the old ones are all at the front. */
    private void prune(long nowMs) {
        while (!entries.isEmpty() && nowMs - entries.peekFirst().atMs > MAX_AGE_MS) {
            entries.removeFirst();
        }
    }
}
