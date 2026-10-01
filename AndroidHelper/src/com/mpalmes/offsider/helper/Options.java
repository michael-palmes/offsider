package com.mpalmes.offsider.helper;

/** Command-line options for the helper's three modes. */
final class Options {
    static final String USAGE = "usage: OffsiderHelper serve [--idle-timeout-ms MS] [--accept-timeout-ms MS]"
            + " | dump [--compressed] [--visible-only] [--app-windows] [--no-idle] [--no-test-tags]"
            + " [--idle-quiet MS] [--idle-timeout MS] | version";
    static final long MIN_TIMEOUT_MS = 100;
    static final long MAX_TIMEOUT_MS = 600000;

    String mode;
    long idleTimeoutMs = 10000;
    long acceptTimeoutMs = 10000;
    DumpOptions dump = DumpOptions.fullTree();

    static Options parse(String[] args) throws HelperFailure {
        if (args.length == 0) {
            throw HelperFailure.usage(USAGE);
        }
        Options o = new Options();
        o.mode = args[0];
        if ("version".equals(o.mode)) {
            if (args.length != 1) {
                throw HelperFailure.usage(USAGE);
            }
        } else if ("serve".equals(o.mode)) {
            o.parseServe(args);
        } else if ("dump".equals(o.mode)) {
            o.parseDump(args);
        } else {
            throw HelperFailure.usage("unknown mode '" + o.mode + "'; " + USAGE);
        }
        return o;
    }

    private void parseServe(String[] args) throws HelperFailure {
        for (int i = 1; i < args.length; i++) {
            String a = args[i];
            if ("--idle-timeout-ms".equals(a) && i + 1 < args.length) {
                idleTimeoutMs = number(args[++i], a, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);
            } else if ("--accept-timeout-ms".equals(a) && i + 1 < args.length) {
                acceptTimeoutMs = number(args[++i], a, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);
            } else {
                throw HelperFailure.usage("unknown or incomplete option '" + a + "'; " + USAGE);
            }
        }
    }

    private void parseDump(String[] args) throws HelperFailure {
        for (int i = 1; i < args.length; i++) {
            String a = args[i];
            if ("--compressed".equals(a)) {
                dump.includeNotImportant = false;
            } else if ("--visible-only".equals(a)) {
                dump.visibleOnly = true;
            } else if ("--app-windows".equals(a)) {
                dump.appWindowsOnly = true;
            } else if ("--no-idle".equals(a)) {
                dump.idle = false;
            } else if ("--no-test-tags".equals(a)) {
                dump.testTags = false;
            } else if ("--idle-quiet".equals(a) && i + 1 < args.length) {
                dump.idleQuietMs = number(args[++i], a, 0, DumpOptions.MAX_IDLE_MS);
            } else if ("--idle-timeout".equals(a) && i + 1 < args.length) {
                dump.idleTimeoutMs = number(args[++i], a, 0, DumpOptions.MAX_IDLE_MS);
            } else {
                throw HelperFailure.usage("unknown or incomplete option '" + a + "'; " + USAGE);
            }
        }
        if (dump.idleQuietMs > dump.idleTimeoutMs) {
            throw HelperFailure.usage("--idle-quiet must not exceed --idle-timeout");
        }
    }

    private static long number(String value, String name, long min, long max) throws HelperFailure {
        long n;
        try {
            n = Long.parseLong(value);
        } catch (NumberFormatException e) {
            throw HelperFailure.usage(name + " must be a whole number, got '" + value + "'");
        }
        if (n < min || n > max) {
            throw HelperFailure.usage(name + " must be between " + min + " and " + max);
        }
        return n;
    }
}
