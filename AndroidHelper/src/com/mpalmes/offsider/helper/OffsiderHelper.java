package com.mpalmes.offsider.helper;

import android.os.Build;
import android.os.Looper;
import android.os.Process;
import android.util.Log;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;

/**
 * Offsider's on-device helper, started as the shell user:
 * CLASSPATH=/data/local/tmp/offsider-helper-HASH.dex app_process /data/local/tmp
 * --nice-name=offsider-helper com.mpalmes.offsider.helper.OffsiderHelper serve
 */
public final class OffsiderHelper {
    static final String NAME = "offsider-helper";
    static final String VERSION = "1.0.0";
    static final int PROTOCOL = 1;
    static final String TAG = "OffsiderHelper";
    static final int EVENT_CAPACITY = 512;

    private static volatile Server server;
    private static volatile boolean ready;
    private static boolean emitted;

    private OffsiderHelper() {
    }

    public static void main(String[] args) {
        Thread.setDefaultUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {
            @Override
            public void uncaughtException(Thread thread, Throwable t) {
                crashed("uncaught exception on thread " + thread.getName(), t);
            }
        });
        int status;
        try {
            prepareMainLooper();
            Options options = Options.parse(args);
            if ("version".equals(options.mode)) {
                print(version());
            } else if ("dump".equals(options.mode)) {
                print(dumpOnce(options));
            } else {
                serve(options);
            }
            status = 0;
        } catch (HelperFailure failure) {
            if (ready) {
                crashed(failure.getMessage(), failure);
            }
            fail(failure);
            status = failure.exitCode;
        } catch (Throwable t) {
            crashed("unexpected error", t);
            status = HelperFailure.EXIT_CRASH;
        }
        Runtime.getRuntime().halt(status);
    }

    private static void serve(Options options) throws HelperFailure {
        Connection connection = new Connection();
        EventLog events = new EventLog(EVENT_CAPACITY);
        Server s = new Server(connection, events, options);
        server = s;
        s.watchStdin();
        long start = System.nanoTime();
        try {
            connection.open();
            connection.configure(false);
            connection.listen(events);
        } catch (HelperFailure failure) {
            connection.close();
            throw failure;
        }
        Log.i(TAG, NAME + " " + VERSION + " protocol " + PROTOCOL + " on SDK " + Build.VERSION.SDK_INT
                + ": connected to UiAutomation in " + (System.nanoTime() - start) / 1000000L + " ms");
        s.run();
    }

    /** Prints the ready line, then silences stdout and stderr: Offsider stops reading the shell stream. */
    static void ready(String socket, String token) throws HelperFailure {
        Json json = new Json().beginObject();
        json.field("event", "ready");
        json.field("protocol", PROTOCOL);
        json.field("helper", VERSION);
        json.field("pid", Process.myPid());
        json.field("socket", socket);
        json.field("token", token);
        json.field("sdkInt", Build.VERSION.SDK_INT);
        try {
            print(json.endObject().toString());
        } catch (IOException e) {
            throw HelperFailure.crash("stdout-failed", "could not print the ready line", e);
        }
        PrintStream discard = new PrintStream(new OutputStream() {
            @Override
            public void write(int b) {
                // Discarded: nothing reads the shell stream after the ready line.
            }

            @Override
            public void write(byte[] b, int off, int len) {
                // Discarded, as above.
            }
        });
        System.setOut(discard);
        System.setErr(discard);
        ready = true;
    }

    private static String version() {
        Json json = new Json().beginObject();
        json.field("ok", true);
        json.field("helper", NAME);
        json.field("version", VERSION);
        json.field("protocol", PROTOCOL);
        json.field("sdkInt", Build.VERSION.SDK_INT);
        return json.endObject().toString();
    }

    /** One dump for checks by hand; the default shows every window and node. */
    private static String dumpOnce(Options options) throws HelperFailure {
        Connection connection = new Connection();
        try {
            connection.open();
            Json json = new Json().beginObject();
            json.field("ok", true);
            json.field("helper", VERSION);
            json.field("protocol", PROTOCOL);
            json.field("mode", "dump");
            json.field("sdkInt", Build.VERSION.SDK_INT);
            json.field("pid", Process.myPid());
            json.field("uid", Process.myUid());
            long seq = Requests.writeDump(json, connection, new EventLog(1), new NodeTable(), options.dump);
            json.field("eventSeq", seq);
            return json.endObject().toString();
        } catch (RequestFailure failure) {
            throw HelperFailure.crash(failure.code, failure.getMessage(), null);
        } catch (RuntimeException e) {
            throw HelperFailure.crash("dump-failed", "reading the accessibility tree failed", e);
        } finally {
            connection.close();
        }
    }

    /** Before the ready line: an error JSON and exit 6. After it: logcat, a bye frame and exit 6. */
    static void crashed(String message, Throwable t) {
        Log.e(TAG, message, t);
        Server s = server;
        if (ready && s != null) {
            throw s.shutdown(HelperFailure.EXIT_CRASH, "crash", message + ": " + HelperFailure.describe(t), null);
        }
        fail(HelperFailure.crash("crashed", message, t));
        Runtime.getRuntime().halt(HelperFailure.EXIT_CRASH);
    }

    /** AccessibilityInteractionClient builds a Handler on the main looper, which app_process never prepares. */
    @SuppressWarnings("deprecation")
    private static void prepareMainLooper() {
        if (Looper.getMainLooper() == null) {
            Looper.prepareMainLooper();
        }
    }

    private static void fail(HelperFailure failure) {
        if (ready) {
            Log.e(TAG, failure.code + ": " + failure.getMessage() + (failure.detail == null ? "" : " (" + failure.detail + ")"));
            return;
        }
        System.err.println(NAME + ": " + failure.code + ": " + failure.getMessage()
                + (failure.detail == null ? "" : " (" + failure.detail + ")"));
        System.err.flush();
        Json json = new Json().beginObject();
        json.field("ok", false);
        json.name("error").beginObject();
        json.field("code", failure.code);
        json.field("message", failure.getMessage());
        json.field("detail", failure.detail);
        json.endObject();
        try {
            print(json.endObject().toString());
        } catch (IOException e) {
            Log.e(TAG, "could not write stdout", e);
        }
    }

    /** Writes at most one JSON line per process, whichever thread gets there first. */
    private static synchronized void print(String text) throws IOException {
        if (emitted) {
            return;
        }
        emitted = true;
        FileOutputStream out = new FileOutputStream(FileDescriptor.out);
        out.write((text + "\n").getBytes(StandardCharsets.UTF_8));
        out.flush();
    }
}
