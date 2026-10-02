package com.mpalmes.offsider.helper;

import android.view.accessibility.AccessibilityNodeInfo;
import java.util.ArrayList;

/** The latest dump's nodes by pre-order index, so an action can name a node from that dump. */
final class NodeTable {
    private final ArrayList<AccessibilityNodeInfo> nodes = new ArrayList<AccessibilityNodeInfo>();
    int generation;

    int begin() {
        generation++;
        nodes.clear();
        return generation;
    }

    int add(AccessibilityNodeInfo node) {
        nodes.add(node);
        return nodes.size() - 1;
    }

    /** The node, or null when it belongs to another dump or the index is out of range. */
    AccessibilityNodeInfo get(long dumpGeneration, long index) {
        if (dumpGeneration != generation || index < 0 || index >= nodes.size()) {
            return null;
        }
        return nodes.get((int) index);
    }
}
