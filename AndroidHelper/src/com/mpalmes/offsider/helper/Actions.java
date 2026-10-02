package com.mpalmes.offsider.helper;

import android.app.UiAutomation;
import android.os.Bundle;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction;
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
        AccessibilityNodeInfo node = automation.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        if (node == null) {
            throw new RequestFailure("no-focus", "nothing has input focus", null);
        }
        CharSequence nodeClass = node.getClassName();
        String nodeId = node.getViewIdResourceName();
        if (!node.isEditable()) {
            throw new RequestFailure("not-editable", "the element with input focus (" + nodeClass
                    + (nodeId == null ? "" : ", id " + nodeId) + ") is not editable", null).node(nodeClass, nodeId);
        }
        int action = AccessibilityAction.ACTION_SET_TEXT.getId();
        if (!hasAction(node, action)) {
            throw RequestFailure.unsupported(nodeClass + " does not offer ACTION_SET_TEXT").node(nodeClass, nodeId);
        }
        Bundle arguments = new Bundle();
        arguments.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text);
        if (!node.performAction(action, arguments)) {
            throw new RequestFailure("action-failed", nodeClass + " refused ACTION_SET_TEXT", null)
                    .node(nodeClass, nodeId);
        }
        node.refresh();
        out.field("className", nodeClass);
        out.field("resourceId", nodeId);
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
