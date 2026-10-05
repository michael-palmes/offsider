package com.mpalmes.offsider.helper;

import android.util.Log;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.json.JSONException;
import org.json.JSONObject;

/** Answers one request at a time with an ok or error envelope that carries the event log's sequence number. */
final class Requests {
    static final long MAX_EVENT_WAIT_MS = 5000;

    /** A reply frame, then a binary payload frame when there is one; quit asks the server to end after sending it. */
    static final class Reply {
        final byte[] bytes;
        final byte[] payload;
        final boolean quit;

        Reply(byte[] bytes, boolean quit) {
            this(bytes, null, quit);
        }

        Reply(byte[] bytes, byte[] payload, boolean quit) {
            this.bytes = bytes;
            this.payload = payload;
            this.quit = quit;
        }
    }

    private final Connection connection;
    private final EventLog events;
    private final NodeTable table = new NodeTable();
    private final Inject inject;

    Requests(Connection connection, EventLog events) {
        this.connection = connection;
        this.events = events;
        inject = new Inject(events);
    }

    Reply handle(byte[] payload) {
        long id = -1;
        String op = null;
        try {
            JSONObject request;
            try {
                request = new JSONObject(new String(payload, StandardCharsets.UTF_8));
            } catch (JSONException e) {
                throw RequestFailure.badRequest("the request is not a JSON object: " + e.getMessage());
            }
            id = request.optLong("id", -1);
            op = string(request, "op", true);
            Json json = new Json().beginObject();
            json.field("id", id);
            json.field("ok", true);
            long seq = -1;
            boolean quit = false;
            byte[] frame = null;
            if ("ping".equals(op)) {
                seq = events.latest();
            } else if ("hello".equals(op)) {
                json.field("helper", OffsiderHelper.VERSION);
                json.field("protocol", OffsiderHelper.PROTOCOL);
                json.name("ops").beginArray();
                for (String name : OffsiderHelper.OPS) {
                    json.value(name);
                }
                json.endArray();
            } else if ("dump".equals(op)) {
                seq = writeDump(json, connection, events, table, DumpOptions.from(request));
            } else if ("display".equals(op)) {
                DisplayProbe.write(json);
                new TreeDumper(json, null, null).metadata(connection.automation());
            } else if ("setProgress".equals(op)) {
                Actions.setProgress(json, table, request);
            } else if ("setText".equals(op)) {
                Actions.setText(json, connection.automation(), request);
            } else if ("events".equals(op)) {
                writeEvents(json, request);
            } else if ("inject".equals(op)) {
                inject.run(json, connection.automation(), request);
            } else if ("screenshot".equals(op)) {
                frame = Capture.run(json, connection.automation(), request);
            } else if ("quit".equals(op)) {
                quit = true;
            } else {
                throw new RequestFailure("unknown-op", "unknown op '" + op + "'", null);
            }
            json.field("eventSeq", seq >= 0 ? seq : events.latest());
            return new Reply(json.endObject().bytes(), frame, quit);
        } catch (RequestFailure failure) {
            return new Reply(error(id, failure, events.latest()), false);
        } catch (RuntimeException e) {
            String code = failureCode(op);
            Log.w(OffsiderHelper.TAG, op + " failed", e);
            RequestFailure failure = new RequestFailure(code, op + " failed", HelperFailure.describe(e));
            return new Reply(error(id, failure, events.latest()), false);
        }
    }

    private static String failureCode(String op) {
        if ("dump".equals(op) || "display".equals(op)) {
            return "dump-failed";
        }
        if ("inject".equals(op)) {
            return "inject-failed";
        }
        return "screenshot".equals(op) ? "capture-failed" : "action-failed";
    }

    /** Writes a dump's fields and returns the event sequence number read just before the walk. */
    static long writeDump(Json json, Connection connection, EventLog events, NodeTable table, DumpOptions options)
            throws RequestFailure {
        long start = System.nanoTime();
        try {
            connection.configure(options.includeNotImportant);
        } catch (HelperFailure failure) {
            throw new RequestFailure("dump-failed", failure.getMessage(), failure.detail);
        }
        long configured = System.nanoTime();
        connection.clearCache();
        long cleared = System.nanoTime();
        boolean idle = options.idle && connection.waitForIdle(options.idleQuietMs, options.idleTimeoutMs);
        long settled = System.nanoTime();
        long seq = events.latest();
        json.field("generation", table.begin());
        json.field("idle", idle);
        DisplayProbe.write(json);
        long displayed = System.nanoTime();
        TreeDumper dumper = new TreeDumper(json, options, table);
        dumper.dump(connection.automation());
        long walked = System.nanoTime();
        json.field("truncated", dumper.truncated);
        json.field("source", dumper.source);
        json.name("stats").beginObject();
        json.field("windows", dumper.windows);
        json.field("trees", dumper.trees);
        json.field("nodes", dumper.nodes);
        json.field("maxDepth", dumper.maxDepth);
        json.field("skippedInvisible", dumper.skippedInvisible);
        json.field("testTags", dumper.testTagsFound);
        json.field("testTagRefreshes", dumper.testTagRefreshes);
        json.endObject();
        json.name("timings").beginObject();
        json.field("configureMs", ms(configured - start));
        json.field("clearMs", ms(cleared - configured));
        json.field("idleMs", ms(settled - cleared));
        json.field("displayMs", ms(displayed - settled));
        json.field("walkMs", ms(walked - displayed));
        json.field("totalMs", ms(walked - start));
        json.endObject();
        return seq;
    }

    private void writeEvents(Json json, JSONObject request) throws RequestFailure {
        long since = whole(request, "since", 0, 0, Long.MAX_VALUE);
        long waitMs = whole(request, "waitMs", 0, 0, MAX_EVENT_WAIT_MS);
        List<EventLog.Entry> found;
        try {
            found = events.await(since, waitMs);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RequestFailure("action-failed", "the events wait was interrupted", null);
        }
        json.name("events").beginArray();
        for (EventLog.Entry entry : found) {
            json.beginObject();
            json.field("seq", entry.seq);
            json.field("type", entry.type);
            json.field("package", entry.pkg);
            json.field("windowId", entry.windowId);
            json.endObject();
        }
        json.endArray();
    }

    static byte[] error(long id, RequestFailure failure, long eventSeq) {
        Json json = new Json().beginObject();
        json.field("id", id);
        json.field("ok", false);
        json.name("error").beginObject();
        json.field("code", failure.code);
        json.field("message", failure.getMessage());
        json.field("detail", failure.detail);
        if (failure.className != null || failure.resourceId != null) {
            json.field("className", failure.className);
            json.field("resourceId", failure.resourceId);
        }
        json.endObject();
        json.field("eventSeq", eventSeq);
        return json.endObject().bytes();
    }

    private static long ms(long nanos) {
        return nanos / 1000000L;
    }

    static String string(JSONObject o, String name, boolean required) throws RequestFailure {
        Object v = o.opt(name);
        if (v == null || v == JSONObject.NULL) {
            if (required) {
                throw RequestFailure.badRequest(name + " is required");
            }
            return null;
        }
        if (v instanceof String) {
            return (String) v;
        }
        throw RequestFailure.badRequest(name + " must be a string");
    }

    static boolean bool(JSONObject o, String name, boolean fallback) throws RequestFailure {
        Object v = o.opt(name);
        if (v == null || v == JSONObject.NULL) {
            return fallback;
        }
        if (v instanceof Boolean) {
            return (Boolean) v;
        }
        throw RequestFailure.badRequest(name + " must be true or false");
    }

    static long whole(JSONObject o, String name, long fallback, long min, long max) throws RequestFailure {
        Object v = o.opt(name);
        if (v == null || v == JSONObject.NULL) {
            if (fallback < min) {
                throw RequestFailure.badRequest(name + " is required");
            }
            return fallback;
        }
        if (v instanceof Integer || v instanceof Long) {
            long n = ((Number) v).longValue();
            if (n >= min && n <= max) {
                return n;
            }
        } else if (v instanceof Number) {
            double d = ((Number) v).doubleValue();
            if (d == Math.rint(d) && d >= min && d <= max) {
                return (long) d;
            }
        }
        throw RequestFailure.badRequest(name + " must be a whole number from " + min + " to " + max);
    }

    static double number(JSONObject o, String name) throws RequestFailure {
        Object v = o.opt(name);
        if (v instanceof Number) {
            double d = ((Number) v).doubleValue();
            if (!Double.isNaN(d) && !Double.isInfinite(d)) {
                return d;
            }
        }
        throw RequestFailure.badRequest(name + " must be a number");
    }

    static JSONObject object(JSONObject o, String name, boolean required) throws RequestFailure {
        Object v = o.opt(name);
        if (v == null || v == JSONObject.NULL) {
            if (required) {
                throw RequestFailure.badRequest(name + " is required");
            }
            return null;
        }
        if (v instanceof JSONObject) {
            return (JSONObject) v;
        }
        throw RequestFailure.badRequest(name + " must be an object");
    }
}
