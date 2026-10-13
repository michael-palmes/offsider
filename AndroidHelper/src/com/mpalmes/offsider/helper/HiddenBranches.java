package com.mpalmes.offsider.helper;

import android.graphics.Rect;
import android.os.Bundle;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.ArrayDeque;
import java.util.List;

/** The branches a dump skipped as not visible that are worth naming: on screen first, then larger, then in the order seen. */
final class HiddenBranches {
    static final int LIMIT = 5;
    static final int LABEL_VISITS = 24;

    private final AccessibilityNodeInfo[] nodes = new AccessibilityNodeInfo[LIMIT];
    private final boolean[] onScreen = new boolean[LIMIT];
    private final long[] areas = new long[LIMIT];
    private final Rect rect = new Rect();
    private int count;

    /** Keeps `node` when it ranks among the best so far; reads only the node's own fields. */
    void offer(AccessibilityNodeInfo node, Rect windowBounds) {
        node.getBoundsInScreen(rect);
        boolean shown = windowBounds != null && Rect.intersects(rect, windowBounds);
        long area = rect.isEmpty() ? 0 : (long) rect.width() * rect.height();
        int at = count;
        while (at > 0 && ranksAbove(shown, area, onScreen[at - 1], areas[at - 1])) {
            at--;
        }
        if (at >= LIMIT) {
            return;
        }
        int last = Math.min(count, LIMIT - 1);
        for (int i = last; i > at; i--) {
            nodes[i] = nodes[i - 1];
            onScreen[i] = onScreen[i - 1];
            areas[i] = areas[i - 1];
        }
        nodes[at] = node;
        onScreen[at] = shown;
        areas[at] = area;
        count = Math.min(count + 1, LIMIT);
    }

    private static boolean ranksAbove(boolean shown, long area, boolean otherShown, long otherArea) {
        return shown != otherShown ? shown : area > otherArea;
    }

    /** Writes "hiddenBranches": each kept root, and its first labelled descendant when it has no label of its own. */
    void write(Json json, boolean testTags) {
        json.name("hiddenBranches").beginArray();
        for (int i = 0; i < count; i++) {
            AccessibilityNodeInfo root = nodes[i];
            json.beginObject();
            fields(json, root);
            if (testTags) {
                json.optional("testTag", testTag(root));
            }
            if (!labelled(root)) {
                AccessibilityNodeInfo child = firstLabelled(root);
                if (child != null) {
                    json.name("children").beginArray().beginObject();
                    fields(json, child);
                    json.endObject().endArray();
                }
            }
            json.endObject();
        }
        json.endArray();
    }

    /** The node format a dump uses, with no index, and text only when the node is neither editable nor a password. */
    private void fields(Json json, AccessibilityNodeInfo n) {
        json.field("i", -1);
        json.optional("class", n.getClassName());
        json.optional("package", n.getPackageName());
        json.optional("resourceId", n.getViewIdResourceName());
        if (!secret(n)) {
            json.optional("text", n.getText());
        }
        json.optional("contentDescription", n.getContentDescription());
        n.getBoundsInScreen(rect);
        json.bounds("bounds", rect.left, rect.top, rect.right, rect.bottom);
        json.flag("editable", n.isEditable());
        json.flag("password", n.isPassword());
        if (!n.isVisibleToUser()) {
            json.field("visibleToUser", false);
        }
    }

    private static boolean secret(AccessibilityNodeInfo n) {
        return n.isEditable() || n.isPassword();
    }

    private static boolean labelled(AccessibilityNodeInfo n) {
        return present(n.getContentDescription()) || (!secret(n) && present(n.getText()));
    }

    private static boolean present(CharSequence text) {
        return text != null && text.length() > 0;
    }

    /** Pre-order search that fetches each child lazily, spending at most LABEL_VISITS fetches. */
    private static AccessibilityNodeInfo firstLabelled(AccessibilityNodeInfo root) {
        ArrayDeque<AccessibilityNodeInfo> path = new ArrayDeque<AccessibilityNodeInfo>();
        ArrayDeque<int[]> next = new ArrayDeque<int[]>();
        path.push(root);
        next.push(new int[] {0});
        int visits = 0;
        while (!path.isEmpty() && visits < LABEL_VISITS) {
            AccessibilityNodeInfo parent = path.peek();
            int[] index = next.peek();
            if (index[0] >= parent.getChildCount()) {
                path.pop();
                next.pop();
                continue;
            }
            AccessibilityNodeInfo child = parent.getChild(index[0]++);
            visits++;
            if (child == null) {
                continue;
            }
            if (labelled(child)) {
                return child;
            }
            path.push(child);
            next.push(new int[] {0});
        }
        return null;
    }

    private static String testTag(AccessibilityNodeInfo n) {
        List<String> available = n.getAvailableExtraData();
        if (available == null || !available.contains(TreeDumper.COMPOSE_TEST_TAG_KEY)) {
            return null;
        }
        CharSequence tag = n.getExtras().getCharSequence(TreeDumper.COMPOSE_TEST_TAG_KEY);
        if (tag == null && n.refreshWithExtraData(TreeDumper.COMPOSE_TEST_TAG_KEY, new Bundle())) {
            tag = n.getExtras().getCharSequence(TreeDumper.COMPOSE_TEST_TAG_KEY);
        }
        return tag == null ? null : tag.toString();
    }
}
