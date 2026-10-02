package com.mpalmes.offsider.helper;

import android.net.Credentials;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.SystemClock;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructPollfd;
import android.util.Log;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.concurrent.atomic.AtomicBoolean;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Serves one authorised client on a randomly named abstract socket, then ends the process on quit,
 * socket EOF, stdin EOF or the idle timeout.
 */
final class Server {
    static final int ROOT_UID = 0;
    static final int SHELL_UID = 2000;
    static final int HELLO_TIMEOUT_MS = 2000;

    private final Connection connection;
    private final EventLog events;
    private final Options options;
    private final Object writeLock = new Object();
    private final AtomicBoolean ending = new AtomicBoolean();
    private volatile OutputStream clientOut;
    private LocalServerSocket listener;

    Server(Connection connection, EventLog events, Options options) {
        this.connection = connection;
        this.events = events;
        this.options = options;
    }

    /** Binds the socket, prints the ready line, serves one authorised client and never returns. */
    void run() throws HelperFailure {
        SecureRandom random = new SecureRandom();
        String name = "offsider-" + hex(random, 16);
        String token = hex(random, 32);
        try {
            listener = new LocalServerSocket(name);
        } catch (IOException e) {
            throw HelperFailure.crash("socket-failed", "could not listen on an abstract socket", e);
        }
        OffsiderHelper.ready(name, token);
        Requests requests = new Requests(connection, events);
        LocalSocket client = accept(token.getBytes(StandardCharsets.UTF_8), requests);
        serve(client, requests);
    }

    /** Ends the process when the shell stream closes, which adbd signals by closing stdin. */
    void watchStdin() {
        Thread watchdog = new Thread(new Runnable() {
            @Override
            public void run() {
                FileInputStream in = new FileInputStream(FileDescriptor.in);
                byte[] buffer = new byte[256];
                String detail = "the shell stream closed";
                try {
                    while (in.read(buffer) >= 0) {
                        continue;
                    }
                } catch (IOException e) {
                    detail = "reading stdin failed: " + e.getMessage();
                }
                throw shutdown(0, "stdin-closed", detail, null);
            }
        }, "OffsiderHelper-stdin");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    private LocalSocket accept(byte[] token, Requests requests) {
        long deadline = SystemClock.uptimeMillis() + options.acceptTimeoutMs;
        while (true) {
            long left = deadline - SystemClock.uptimeMillis();
            if (left <= 0 || !readable(listener.getFileDescriptor(), left)) {
                throw shutdown(HelperFailure.EXIT_NO_CLIENT, null,
                        "no authorised client within " + options.acceptTimeoutMs + " ms", null);
            }
            LocalSocket socket;
            try {
                socket = listener.accept();
            } catch (IOException e) {
                Log.w(OffsiderHelper.TAG, "accept failed: " + e.getMessage());
                SystemClock.sleep(10);
                continue;
            }
            if (authorised(socket, token, requests)) {
                try {
                    listener.close();
                } catch (IOException e) {
                    Log.w(OffsiderHelper.TAG, "closing the listening socket failed: " + e.getMessage());
                }
                return socket;
            }
            closeQuietly(socket);
        }
    }

    /** Peer uid root or shell, and a first frame that is hello with the token; answers that hello. */
    private boolean authorised(LocalSocket socket, byte[] token, Requests requests) {
        Credentials peer;
        try {
            peer = socket.getPeerCredentials();
        } catch (IOException e) {
            Log.w(OffsiderHelper.TAG, "refused a client without peer credentials: " + e.getMessage());
            return false;
        }
        int uid = peer.getUid();
        if (uid != ROOT_UID && uid != SHELL_UID) {
            Log.w(OffsiderHelper.TAG, "refused a client with uid " + uid + " pid " + peer.getPid());
            return false;
        }
        byte[] payload;
        try {
            socket.setSoTimeout(HELLO_TIMEOUT_MS);
            if (!readable(socket.getFileDescriptor(), HELLO_TIMEOUT_MS)) {
                Log.w(OffsiderHelper.TAG, "refused a client with uid " + uid + ": no hello within "
                        + HELLO_TIMEOUT_MS + " ms");
                return false;
            }
            payload = Frames.read(socket.getInputStream());
        } catch (IOException e) {
            Log.w(OffsiderHelper.TAG, "refused a client with uid " + uid + ": " + e.getMessage());
            return false;
        }
        if (payload == null || !isHelloWithToken(payload, token)) {
            Log.w(OffsiderHelper.TAG, "refused a client with uid " + uid + " pid " + peer.getPid()
                    + ": its first frame was not hello with the token");
            return false;
        }
        Log.i(OffsiderHelper.TAG, "accepted a client with uid " + uid + " pid " + peer.getPid());
        try {
            socket.setSoTimeout((int) options.idleTimeoutMs);
            clientOut = socket.getOutputStream();
        } catch (IOException e) {
            Log.w(OffsiderHelper.TAG, "could not set up the client socket: " + e.getMessage());
            return false;
        }
        return send(requests.handle(payload).bytes);
    }

    private static boolean isHelloWithToken(byte[] payload, byte[] token) {
        JSONObject hello;
        try {
            hello = new JSONObject(new String(payload, StandardCharsets.UTF_8));
        } catch (JSONException e) {
            return false;
        }
        Object op = hello.opt("op");
        Object given = hello.opt("token");
        if (!"hello".equals(op) || !(given instanceof String)) {
            return false;
        }
        return MessageDigest.isEqual(token, ((String) given).getBytes(StandardCharsets.UTF_8));
    }

    private void serve(LocalSocket client, Requests requests) {
        InputStream in;
        try {
            in = client.getInputStream();
        } catch (IOException e) {
            throw shutdown(0, null, "the client socket failed: " + e.getMessage(), null);
        }
        FileDescriptor fd = client.getFileDescriptor();
        while (true) {
            if (!readable(fd, options.idleTimeoutMs)) {
                throw shutdown(0, "idle", "no request within " + options.idleTimeoutMs + " ms", null);
            }
            byte[] payload;
            try {
                payload = Frames.read(in);
            } catch (IOException e) {
                throw shutdown(0, null, "reading a request failed: " + e.getMessage(), null);
            }
            if (payload == null) {
                throw shutdown(0, null, "the client closed the socket", null);
            }
            Requests.Reply reply = requests.handle(payload);
            if (reply.quit) {
                throw shutdown(0, "quit", null, reply.bytes);
            }
            if (!send(reply.bytes)) {
                throw shutdown(0, null, "the client stopped reading", null);
            }
        }
    }

    private boolean send(byte[] frame) {
        synchronized (writeLock) {
            OutputStream out = clientOut;
            if (out == null || ending.get()) {
                return false;
            }
            try {
                Frames.write(out, frame);
                return true;
            } catch (IOException e) {
                Log.w(OffsiderHelper.TAG, "writing a reply failed: " + e.getMessage());
                return false;
            }
        }
    }

    /**
     * Disconnects UiAutomation so the slot is free, sends the final reply and a bye when a client is
     * connected, then halts. Never returns; the return type lets callers write {@code throw shutdown(...)}.
     */
    IllegalStateException shutdown(int status, String byeReason, String detail, byte[] finalReply) {
        if (!ending.compareAndSet(false, true)) {
            while (true) {
                SystemClock.sleep(1000);
            }
        }
        Log.i(OffsiderHelper.TAG, "exiting with status " + status + (byeReason == null ? "" : " (" + byeReason + ")")
                + (detail == null ? "" : ": " + detail));
        String problem = connection.close();
        if (problem != null) {
            Log.w(OffsiderHelper.TAG, "disconnecting UiAutomation failed: " + problem);
        }
        synchronized (writeLock) {
            OutputStream out = clientOut;
            if (out != null) {
                try {
                    if (finalReply != null) {
                        Frames.write(out, finalReply);
                    }
                    if (byeReason != null) {
                        Frames.write(out, bye(byeReason, detail));
                    }
                } catch (IOException e) {
                    Log.i(OffsiderHelper.TAG, "the client did not get the last frame: " + e.getMessage());
                }
            }
            Runtime.getRuntime().halt(status);
        }
        return new IllegalStateException("halt returned");
    }

    static byte[] bye(String reason, String detail) {
        Json json = new Json().beginObject();
        json.field("event", "bye");
        json.field("reason", reason);
        json.field("detail", detail);
        return json.endObject().bytes();
    }

    /** True when the descriptor has data, an end of stream or an error to read before the timeout. */
    static boolean readable(FileDescriptor fd, long timeoutMs) {
        StructPollfd poll = new StructPollfd();
        poll.fd = fd;
        poll.events = (short) OsConstants.POLLIN;
        long deadline = SystemClock.uptimeMillis() + timeoutMs;
        while (true) {
            long left = Math.max(0, deadline - SystemClock.uptimeMillis());
            try {
                return Os.poll(new StructPollfd[] {poll}, (int) Math.min(left, Integer.MAX_VALUE)) > 0;
            } catch (ErrnoException e) {
                if (e.errno != OsConstants.EINTR) {
                    return true;
                }
            }
        }
    }

    private static String hex(SecureRandom random, int bytes) {
        byte[] raw = new byte[bytes];
        random.nextBytes(raw);
        StringBuilder sb = new StringBuilder(bytes * 2);
        for (byte b : raw) {
            sb.append(Character.forDigit((b >> 4) & 0xf, 16)).append(Character.forDigit(b & 0xf, 16));
        }
        return sb.toString();
    }

    private static void closeQuietly(LocalSocket socket) {
        try {
            socket.close();
        } catch (IOException e) {
            Log.w(OffsiderHelper.TAG, "closing a refused client failed: " + e.getMessage());
        }
    }
}
