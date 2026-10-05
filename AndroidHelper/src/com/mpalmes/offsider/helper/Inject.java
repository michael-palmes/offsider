package com.mpalmes.offsider.helper;

import android.app.UiAutomation;
import android.os.SystemClock;
import android.util.Log;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Touches and keys through UiAutomation.injectInputEvent on display 0. Every step is checked before the first
 * event; fingers and keys held at the end of a request stay down for the next one, as one gesture.
 */
final class Inject {
    static final int MAX_STEPS = 2000;
    static final int MAX_POINTERS = 10;
    static final int MAX_MOVES = 1000;
    static final int MAX_TEXT = 4096;
    static final long MAX_STEP_MS = 30000;
    static final long MAX_REQUEST_MS = 60000;
    static final double MAX_COORDINATE = 100000;

    private static final int TAP = 0;
    private static final int SWIPE = 1;
    private static final int TOUCH = 2;
    private static final int KEY = 3;
    private static final int TEXT = 4;
    private static final int PAUSE = 5;

    private static final int DOWN = 0;
    private static final int MOVE = 1;
    private static final int UP = 2;
    private static final int PRESS = 3;

    private static final class Step {
        int kind;
        int phase;
        float x;
        float y;
        float toX;
        float toY;
        long ms;
        int moves;
        int pointer;
        int code;
        int meta;
        KeyEvent[] keys;
    }

    /** Fingers on the glass by pointer id, in id order, and the gesture's shared down time. */
    private final TreeMap<Integer, float[]> fingers = new TreeMap<Integer, float[]>();
    private long gestureDownTime;
    /** Keys held down by key code, with each key's down time. */
    private final TreeMap<Integer, Long> heldKeys = new TreeMap<Integer, Long>();
    private final EventLog events;

    Inject(EventLog events) {
        this.events = events;
    }

    void run(Json json, UiAutomation automation, JSONObject request) throws RequestFailure {
        boolean sync = Requests.bool(request, "sync", true);
        List<Step> steps = parse(request);
        long seqBefore = events.latest();
        long start = SystemClock.uptimeMillis();
        long[] stepMs = new long[steps.size()];
        int index = 0;
        try {
            for (; index < steps.size(); index++) {
                long stepStart = SystemClock.uptimeMillis();
                if (!dispatch(automation, steps.get(index), sync)) {
                    release(automation);
                    throw new RequestFailure("inject-refused", "Android did not dispatch step " + index + " ("
                            + kindName(steps.get(index).kind) + ")", null);
                }
                stepMs[index] = SystemClock.uptimeMillis() - stepStart;
            }
        } catch (SecurityException e) {
            release(automation);
            throw new RequestFailure("inject-failed", "Android refused to inject step " + index,
                    HelperFailure.describe(e));
        }
        json.name("steps").beginArray();
        for (long ms : stepMs) {
            json.beginObject();
            json.field("dispatched", true);
            json.field("ms", ms);
            json.endObject();
        }
        json.endArray();
        json.field("eventSeqBefore", seqBefore);
        json.field("totalMs", SystemClock.uptimeMillis() - start);
    }

    /** Checks every step against the fingers and keys held now, so a bad request injects nothing. */
    private List<Step> parse(JSONObject request) throws RequestFailure {
        Object raw = request.opt("steps");
        if (!(raw instanceof JSONArray)) {
            throw RequestFailure.badRequest("steps must be an array");
        }
        JSONArray array = (JSONArray) raw;
        if (array.length() == 0 || array.length() > MAX_STEPS) {
            throw RequestFailure.badRequest("steps must hold 1 to " + MAX_STEPS + " steps");
        }
        TreeMap<Integer, Boolean> down = new TreeMap<Integer, Boolean>();
        for (Integer id : fingers.keySet()) {
            down.put(id, Boolean.TRUE);
        }
        long waited = 0;
        List<Step> steps = new ArrayList<Step>(array.length());
        KeyCharacterMap keyboard = null;
        for (int i = 0; i < array.length(); i++) {
            Object item = array.opt(i);
            if (!(item instanceof JSONObject)) {
                throw RequestFailure.badRequest("step " + i + " must be an object");
            }
            JSONObject o = (JSONObject) item;
            String kind = Requests.string(o, "kind", true);
            Step step = new Step();
            if ("tap".equals(kind)) {
                step.kind = TAP;
                point(step, o, i);
                if (!down.isEmpty()) {
                    throw RequestFailure.badRequest("step " + i + ": tap while a finger is down");
                }
            } else if ("swipe".equals(kind)) {
                step.kind = SWIPE;
                step.x = coordinate(o, "fromX", i);
                step.y = coordinate(o, "fromY", i);
                step.toX = coordinate(o, "toX", i);
                step.toY = coordinate(o, "toY", i);
                step.ms = Requests.whole(o, "durationMs", -1, 0, MAX_STEP_MS);
                step.moves = (int) Requests.whole(o, "moves", 1, 1, MAX_MOVES);
                waited += step.ms;
                if (!down.isEmpty()) {
                    throw RequestFailure.badRequest("step " + i + ": swipe while a finger is down");
                }
            } else if ("touch".equals(kind)) {
                step.kind = TOUCH;
                step.phase = phase(o, i, false);
                point(step, o, i);
                step.pointer = (int) Requests.whole(o, "pointer", 0, 0, MAX_POINTERS - 1);
                boolean isDown = down.containsKey(step.pointer);
                if (step.phase == DOWN && isDown) {
                    throw RequestFailure.badRequest("step " + i + ": pointer " + step.pointer + " is already down");
                }
                if (step.phase != DOWN && !isDown) {
                    throw RequestFailure.badRequest("step " + i + ": pointer " + step.pointer + " is not down");
                }
                if (step.phase == DOWN) {
                    down.put(step.pointer, Boolean.TRUE);
                } else if (step.phase == UP) {
                    down.remove(step.pointer);
                }
            } else if ("key".equals(kind)) {
                step.kind = KEY;
                step.phase = phase(o, i, true);
                step.code = (int) Requests.whole(o, "code", -1, 1, KeyEvent.getMaxKeyCode());
                step.meta = (int) Requests.whole(o, "meta", 0, 0, Integer.MAX_VALUE);
            } else if ("text".equals(kind)) {
                step.kind = TEXT;
                String text = Requests.string(o, "text", true);
                if (text.length() > MAX_TEXT) {
                    throw RequestFailure.badRequest("step " + i + ": text is longer than " + MAX_TEXT + " characters");
                }
                if (keyboard == null) {
                    keyboard = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD);
                }
                step.keys = keyboard.getEvents(text.toCharArray());
                if (step.keys == null) {
                    throw new RequestFailure("unsupported-text", "step " + i
                            + ": the virtual keyboard has no keys for some of the text", null);
                }
            } else if ("pause".equals(kind)) {
                step.kind = PAUSE;
                step.ms = Requests.whole(o, "ms", -1, 0, MAX_STEP_MS);
                waited += step.ms;
            } else {
                throw RequestFailure.badRequest("step " + i + ": unknown kind '" + kind + "'");
            }
            if (waited > MAX_REQUEST_MS) {
                throw RequestFailure.badRequest("the steps wait more than " + MAX_REQUEST_MS + " ms in all");
            }
            steps.add(step);
        }
        return steps;
    }

    private boolean dispatch(UiAutomation automation, Step step, boolean sync) {
        long now = SystemClock.uptimeMillis();
        switch (step.kind) {
            case TAP:
                gestureDownTime = now;
                fingers.put(0, new float[] {step.x, step.y});
                if (!motion(automation, MotionEvent.ACTION_DOWN, 0, now, sync)) {
                    return false;
                }
                boolean up = motion(automation, MotionEvent.ACTION_UP, 0, SystemClock.uptimeMillis(), sync);
                fingers.clear();
                return up;
            case SWIPE:
                return swipe(automation, step, sync);
            case TOUCH:
                return touch(automation, step, now, sync);
            case KEY:
                return key(automation, step, now, sync);
            case TEXT:
                for (KeyEvent event : step.keys) {
                    KeyEvent timed = KeyEvent.changeTimeRepeat(event, SystemClock.uptimeMillis(), 0);
                    timed.setSource(InputDevice.SOURCE_KEYBOARD);
                    if (!inject(automation, timed, sync)) {
                        return false;
                    }
                }
                return true;
            default:
                SystemClock.sleep(step.ms);
                return true;
        }
    }

    /** Down, moves spaced evenly over the duration (sent without waiting), the last on the end point, then up there. */
    private boolean swipe(UiAutomation automation, Step step, boolean sync) {
        gestureDownTime = SystemClock.uptimeMillis();
        fingers.put(0, new float[] {step.x, step.y});
        if (!motion(automation, MotionEvent.ACTION_DOWN, 0, gestureDownTime, sync)) {
            return false;
        }
        long spacing = step.ms / step.moves;
        for (int i = 1; i <= step.moves; i++) {
            if (spacing > 0) {
                SystemClock.sleep(spacing);
            }
            float fraction = (float) i / step.moves;
            fingers.put(0, new float[] {step.x + (step.toX - step.x) * fraction, step.y + (step.toY - step.y) * fraction});
            if (!motion(automation, MotionEvent.ACTION_MOVE, 0, SystemClock.uptimeMillis(), false)) {
                return false;
            }
        }
        fingers.put(0, new float[] {step.toX, step.toY});
        boolean up = motion(automation, MotionEvent.ACTION_UP, 0, SystemClock.uptimeMillis(), sync);
        fingers.clear();
        return up;
    }

    private boolean touch(UiAutomation automation, Step step, long now, boolean sync) {
        if (step.phase == DOWN) {
            boolean first = fingers.isEmpty();
            if (first) {
                gestureDownTime = now;
            }
            fingers.put(step.pointer, new float[] {step.x, step.y});
            int action = first ? MotionEvent.ACTION_DOWN : MotionEvent.ACTION_POINTER_DOWN;
            return motion(automation, action, step.pointer, now, sync);
        }
        fingers.put(step.pointer, new float[] {step.x, step.y});
        if (step.phase == MOVE) {
            return motion(automation, MotionEvent.ACTION_MOVE, step.pointer, now, sync);
        }
        int action = fingers.size() == 1 ? MotionEvent.ACTION_UP : MotionEvent.ACTION_POINTER_UP;
        boolean sent = motion(automation, action, step.pointer, now, sync);
        fingers.remove(step.pointer);
        return sent;
    }

    private boolean key(UiAutomation automation, Step step, long now, boolean sync) {
        if (step.phase == UP) {
            Long downTime = heldKeys.remove(step.code);
            return inject(automation, keyEvent(downTime == null ? now : downTime, now, KeyEvent.ACTION_UP, step), sync);
        }
        if (!inject(automation, keyEvent(now, now, KeyEvent.ACTION_DOWN, step), sync)) {
            return false;
        }
        if (step.phase == DOWN) {
            heldKeys.put(step.code, now);
            return true;
        }
        return inject(automation, keyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, step), sync);
    }

    private static KeyEvent keyEvent(long downTime, long eventTime, int action, Step step) {
        return new KeyEvent(downTime, eventTime, action, step.code, 0, step.meta, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0,
                InputDevice.SOURCE_KEYBOARD);
    }

    /** One event with every finger now down; a pointer action carries the acting finger's index. */
    private boolean motion(UiAutomation automation, int action, int pointer, long eventTime, boolean sync) {
        int count = fingers.size();
        MotionEvent.PointerProperties[] properties = new MotionEvent.PointerProperties[count];
        MotionEvent.PointerCoords[] coords = new MotionEvent.PointerCoords[count];
        int acting = 0;
        int i = 0;
        for (Map.Entry<Integer, float[]> finger : fingers.entrySet()) {
            properties[i] = new MotionEvent.PointerProperties();
            properties[i].id = finger.getKey();
            properties[i].toolType = MotionEvent.TOOL_TYPE_FINGER;
            coords[i] = new MotionEvent.PointerCoords();
            coords[i].x = finger.getValue()[0];
            coords[i].y = finger.getValue()[1];
            coords[i].pressure = 1f;
            coords[i].size = 1f;
            if (finger.getKey() == pointer) {
                acting = i;
            }
            i++;
        }
        if (action == MotionEvent.ACTION_POINTER_DOWN || action == MotionEvent.ACTION_POINTER_UP) {
            action |= acting << MotionEvent.ACTION_POINTER_INDEX_SHIFT;
        }
        MotionEvent event = MotionEvent.obtain(gestureDownTime, eventTime, action, count, properties, coords, 0, 0,
                1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
        try {
            return inject(automation, event, sync);
        } finally {
            event.recycle();
        }
    }

    private static boolean inject(UiAutomation automation, InputEvent event, boolean sync) {
        return automation.injectInputEvent(event, sync);
    }

    /** Best effort after a failure: cancels the gesture and lets go of held keys, so nothing stays pressed. */
    private void release(UiAutomation automation) {
        long now = SystemClock.uptimeMillis();
        try {
            if (!fingers.isEmpty()) {
                motion(automation, MotionEvent.ACTION_CANCEL, 0, now, false);
            }
            for (Map.Entry<Integer, Long> held : heldKeys.entrySet()) {
                inject(automation, new KeyEvent(held.getValue(), now, KeyEvent.ACTION_UP, held.getKey(), 0, 0,
                        KeyCharacterMap.VIRTUAL_KEYBOARD, 0, KeyEvent.FLAG_CANCELED, InputDevice.SOURCE_KEYBOARD), false);
            }
        } catch (RuntimeException e) {
            Log.w(OffsiderHelper.TAG, "releasing input after a failed inject failed", e);
        } finally {
            fingers.clear();
            heldKeys.clear();
        }
    }

    private static void point(Step step, JSONObject o, int index) throws RequestFailure {
        step.x = coordinate(o, "x", index);
        step.y = coordinate(o, "y", index);
    }

    private static float coordinate(JSONObject o, String name, int index) throws RequestFailure {
        double value;
        try {
            value = Requests.number(o, name);
        } catch (RequestFailure failure) {
            throw RequestFailure.badRequest("step " + index + ": " + failure.getMessage());
        }
        if (Math.abs(value) > MAX_COORDINATE) {
            throw RequestFailure.badRequest("step " + index + ": " + name + " is outside the screen");
        }
        return (float) value;
    }

    private static int phase(JSONObject o, int index, boolean key) throws RequestFailure {
        String phase = Requests.string(o, "phase", true);
        if ("down".equals(phase)) {
            return DOWN;
        }
        if ("up".equals(phase)) {
            return UP;
        }
        if (!key && "move".equals(phase)) {
            return MOVE;
        }
        if (key && "press".equals(phase)) {
            return PRESS;
        }
        throw RequestFailure.badRequest("step " + index + ": phase must be " + (key ? "down, up or press" : "down, move or up"));
    }

    private static String kindName(int kind) {
        switch (kind) {
            case TAP:
                return "tap";
            case SWIPE:
                return "swipe";
            case TOUCH:
                return "touch";
            case KEY:
                return "key";
            case TEXT:
                return "text";
            default:
                return "pause";
        }
    }
}
