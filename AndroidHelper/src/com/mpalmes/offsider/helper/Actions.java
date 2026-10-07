package com.mpalmes.offsider.helper;

import android.app.UiAutomation;
import android.os.Bundle;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction;
import android.view.accessibility.AccessibilityWindowInfo;
import java.util.List;
import org.json.JSONObject;

/** Accessibility actions: a range value on a node from the latest dump, and text on the input-focused field. */
final class Actions {
    private Actions() {
    }

    /** Sets the node's progress in the units its RangeInfo reports, then writes "range" as it reads afterwards. */
    static void setProgress(Json out, NodeTable table, JSONObject request) throws RequestFailure {
        JSONObject ref = Requests.object(request, "node", true);
        long generation = Requests.whole(ref, "generation", -1, 0, Integer.MAX_VALUE);
        long index = Requests.whole(ref, "index", -1, 0, Integer.MAX_VALUE);
        String className = Requests.string(ref, "className", false);
        String resourceId = Requests.string(ref, "resourceId", false);
        double value = Requests.number(request, "value");
        JSONObject expect = Requests.object(request, "expect", false);

        AccessibilityNodeInfo node = table.get(generation, index);
        if (node == null) {
            throw RequestFailure.staleNode("node " + index + " of dump " + generation
                    + " is not in the latest dump (" + table.generation + ")");
        }
        if (!node.refresh()) {
            throw RequestFailure.staleNode("node " + index + " of dump " + generation + " left the screen");
        }
        if (!same(className, node.getClassName()) || !same(resourceId, node.getViewIdResourceName())) {
            throw RequestFailure.staleNode("node " + index + " is now " + node.getClassName()
                    + " with id " + node.getViewIdResourceName());
        }
        AccessibilityNodeInfo.RangeInfo range = node.getRangeInfo();
        if (range == null) {
            throw RequestFailure.unsupported(node.getClassName() + " has no range");
        }
        if (expect != null) {
            float min = (float) Requests.number(expect, "min");
            float max = (float) Requests.number(expect, "max");
            if (min != range.getMin() || max != range.getMax()) {
                throw RequestFailure.staleNode("the range is now " + range.getMin() + " to " + range.getMax());
            }
        }
        int action = AccessibilityAction.ACTION_SET_PROGRESS.getId();
        if (!hasAction(node, action)) {
            throw RequestFailure.unsupported(node.getClassName() + " does not offer ACTION_SET_PROGRESS");
        }
        Bundle arguments = new Bundle();
        arguments.putFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE, (float) value);
        if (!node.performAction(action, arguments)) {
            throw new RequestFailure("action-failed", node.getClassName() + " refused ACTION_SET_PROGRESS", null);
        }
        node.refresh();
        AccessibilityNodeInfo.RangeInfo after = node.getRangeInfo();
        out.name("range");
        if (after == null) {
            out.nullValue();
        } else {
            TreeDumper.range(out, after);
        }
    }

    /** Replaces the text of the input-focused field; "length" is in UTF-16 units, null for passwords. */
    static void setText(Json out, UiAutomation automation, JSONObject request) throws RequestFailure {
        String text = Requests.string(request, "text", true);
        AccessibilityNodeInfo node = editableFocus(automation);
        CharSequence nodeClass = node.getClassName();
        String nodeId = node.getViewIdResourceName();
        int type = node.getInputType();
        int action = AccessibilityAction.ACTION_SET_TEXT.getId();
        if (!hasAction(node, action)) {
            throw RequestFailure.unsupported(nodeClass + " does not offer ACTION_SET_TEXT").field(nodeClass, nodeId, type);
        }
        Bundle arguments = new Bundle();
        arguments.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text);
        if (!node.performAction(action, arguments)) {
            throw new RequestFailure("action-failed", nodeClass + " refused ACTION_SET_TEXT", null)
                    .field(nodeClass, nodeId, type);
        }
        node.refresh();
        writeField(out, node);
    }

    /** Pastes over all of the focused field's text; refuses password fields and, given an expected class or id, other fields. */
    static void paste(Json out, UiAutomation automation, JSONObject request) throws RequestFailure {
        boolean expecting = request.has("expectClass") || request.has("expectResourceId");
        String expectClass = Requests.string(request, "expectClass", false);
        String expectId = Requests.string(request, "expectResourceId", false);
        AccessibilityNodeInfo node = editableFocus(automation);
        CharSequence nodeClass = node.getClassName();
        String nodeId = node.getViewIdResourceName();
        int type = node.getInputType();
        if (node.isPassword()) {
            throw new RequestFailure("secure-refused", "the field with input focus is a password field", null)
                    .field(nodeClass, nodeId, type);
        }
        if (expecting && (!same(expectClass, nodeClass) || !same(expectId, nodeId))) {
            throw new RequestFailure("focus-moved", "the field with input focus is " + nodeClass
                    + (nodeId == null ? " with no id" : " with id " + nodeId) + ", not the expected field", null)
                    .field(nodeClass, nodeId, type);
        }
        int paste = AccessibilityAction.ACTION_PASTE.getId();
        if (!hasAction(node, paste)) {
            throw RequestFailure.unsupported(nodeClass + " does not offer ACTION_PASTE").field(nodeClass, nodeId, type);
        }
        CharSequence current = node.isShowingHintText() ? null : node.getText();
        int length = current == null ? 0 : current.length();
        if (length > 0 && !(node.getTextSelectionStart() == 0 && node.getTextSelectionEnd() == length)) {
            selectAll(node, length);
        }
        if (!node.performAction(paste)) {
            throw new RequestFailure("action-failed", nodeClass + " refused ACTION_PASTE", null).field(nodeClass, nodeId, type);
        }
        node.refresh();
        writeField(out, node);
    }

    /** Without the whole text selected a paste would add to it, so a field that cannot select it all is refused. */
    private static void selectAll(AccessibilityNodeInfo node, int length) throws RequestFailure {
        CharSequence nodeClass = node.getClassName();
        String nodeId = node.getViewIdResourceName();
        int type = node.getInputType();
        int select = AccessibilityAction.ACTION_SET_SELECTION.getId();
        if (!hasAction(node, select)) {
            throw RequestFailure.unsupported(nodeClass + " cannot select its text (no ACTION_SET_SELECTION)")
                    .field(nodeClass, nodeId, type);
        }
        Bundle selection = new Bundle();
        selection.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0);
        selection.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, length);
        if (!node.performAction(select, selection)) {
            throw RequestFailure.unsupported(nodeClass + " refused ACTION_SET_SELECTION")
                    .field(nodeClass, nodeId, type);
        }
    }

    /** The input-focused node when it is editable, else the only other focused text field. */
    private static AccessibilityNodeInfo editableFocus(UiAutomation automation) throws RequestFailure {
        AccessibilityNodeInfo node = automation.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        if (node != null && node.isEditable()) {
            return node;
        }
        // A web view can hold input focus while the text field a tap focused is focused too.
        AccessibilityNodeInfo editable = onlyFocusedEditable(automation);
        if (editable != null) {
            return editable;
        }
        if (node == null) {
            throw new RequestFailure("no-focus", "nothing has input focus", null);
        }
        CharSequence nodeClass = node.getClassName();
        String nodeId = node.getViewIdResourceName();
        throw new RequestFailure("not-editable", "the element with input focus (" + nodeClass
                + (nodeId == null ? "" : ", id " + nodeId) + ") is not editable", null)
                .field(nodeClass, nodeId, node.getInputType());
    }

    /** The one focused editable node across windows, or null when there is none or more than one. */
    private static AccessibilityNodeInfo onlyFocusedEditable(UiAutomation automation) {
        AccessibilityNodeInfo[] found = new AccessibilityNodeInfo[1];
        int[] count = new int[1];
        List<AccessibilityWindowInfo> windows = automation.getWindows();
        if (windows != null) {
            for (AccessibilityWindowInfo window : windows) {
                collectFocusedEditable(window.getRoot(), found, count);
            }
        }
        if (count[0] == 0) {
            collectFocusedEditable(automation.getRootInActiveWindow(), found, count);
        }
        return count[0] == 1 ? found[0] : null;
    }

    private static void collectFocusedEditable(AccessibilityNodeInfo node, AccessibilityNodeInfo[] found, int[] count) {
        if (node == null || count[0] > 1) {
            return;
        }
        if (node.isFocused() && node.isEditable()) {
            count[0]++;
            found[0] = node;
        }
        int children = node.getChildCount();
        for (int i = 0; i < children && count[0] < 2; i++) {
            collectFocusedEditable(node.getChild(i), found, count);
        }
    }

    /** "className", "resourceId", "inputType", then "length" in UTF-16 units, null for passwords. */
    private static void writeField(Json out, AccessibilityNodeInfo node) {
        out.field("className", node.getClassName());
        out.field("resourceId", node.getViewIdResourceName());
        out.field("inputType", node.getInputType());
        out.name("length");
        if (node.isPassword()) {
            out.nullValue();
        } else {
            CharSequence now = node.isShowingHintText() ? null : node.getText();
            out.value(now == null ? 0 : now.length());
        }
    }

    static boolean hasAction(AccessibilityNodeInfo node, int id) {
        List<AccessibilityAction> actions = node.getActionList();
        if (actions == null) {
            return false;
        }
        for (AccessibilityAction a : actions) {
            if (a.getId() == id) {
                return true;
            }
        }
        return false;
    }

    private static boolean same(String expected, CharSequence actual) {
        if (expected == null || actual == null) {
            return expected == null && actual == null;
        }
        return expected.contentEquals(actual);
    }
}
