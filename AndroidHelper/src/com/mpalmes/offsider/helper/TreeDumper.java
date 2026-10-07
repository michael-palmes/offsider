package com.mpalmes.offsider.helper;

import android.app.UiAutomation;
import android.graphics.Rect;
import android.graphics.Region;
import android.os.Build;
import android.os.Bundle;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import java.util.List;

/** Writes the window list as JSON, with node trees for the windows the options ask for. */
final class TreeDumper {
    static final String ROLE_DESCRIPTION_KEY = "AccessibilityNodeInfo.roleDescription";
    static final String COMPOSE_TEST_TAG_KEY = "androidx.compose.ui.semantics.testTag";
    static final int MAX_DEPTH = 200;
    static final int MAX_NODES = 20000;

    private final Json json;
    private final DumpOptions options;
    private final NodeTable table;
    private final Rect rect = new Rect();

    String source;
    int windows;
    int trees;
    int nodes;
    int maxDepth;
    private List<AccessibilityWindowInfo> windowList;
    private boolean keyboardShown;
    private boolean keepHidden;
    private AccessibilityWindowInfo behindKeyboard;
    private Region keyboardRegion;
    private Region coverRegion;
    int skippedInvisible;
    int testTagsFound;
    int testTagRefreshes;
    boolean truncated;

    TreeDumper(Json json, DumpOptions options, NodeTable table) {
        this.json = json;
        this.options = options;
        this.table = table;
    }

    /** Writes "windows"; with app scope only the app window and input methods carry a root. */
    void dump(UiAutomation automation) {
        json.name("windows").beginArray();
        List<AccessibilityWindowInfo> list = automation.getWindows();
        if (list == null || list.isEmpty()) {
            source = "getRootInActiveWindow";
            AccessibilityNodeInfo root = automation.getRootInActiveWindow();
            if (root != null) {
                rootOnlyWindow(root);
            }
        } else {
            source = "getWindows";
            AccessibilityWindowInfo app = options.appWindowsOnly ? appWindow(automation, list) : null;
            windowList = list;
            keyboardShown = false;
            for (AccessibilityWindowInfo window : list) {
                keyboardShown = keyboardShown || window.getType() == AccessibilityWindowInfo.TYPE_INPUT_METHOD;
            }
            for (AccessibilityWindowInfo window : list) {
                boolean tree = !options.appWindowsOnly || window == app
                        || window.getType() == AccessibilityWindowInfo.TYPE_INPUT_METHOD;
                window(window, tree);
            }
        }
        json.endArray();
    }

    /** Writes "windows" with metadata only. */
    void metadata(UiAutomation automation) {
        json.name("windows").beginArray();
        List<AccessibilityWindowInfo> list = automation.getWindows();
        if (list != null) {
            for (AccessibilityWindowInfo window : list) {
                window(window, false);
            }
        }
        json.endArray();
    }

    /** The active window unless it is the keyboard, else the topmost application window, else the window of the active root. */
    static AccessibilityWindowInfo appWindow(UiAutomation automation, List<AccessibilityWindowInfo> list) {
        for (AccessibilityWindowInfo window : list) {
            if (window.isActive() && window.getType() != AccessibilityWindowInfo.TYPE_INPUT_METHOD) {
                return window;
            }
        }
        AccessibilityWindowInfo top = null;
        for (AccessibilityWindowInfo window : list) {
            if (window.getType() == AccessibilityWindowInfo.TYPE_APPLICATION
                    && (top == null || window.getLayer() > top.getLayer())) {
                top = window;
            }
        }
        if (top != null) {
            return top;
        }
        AccessibilityNodeInfo root = automation.getRootInActiveWindow();
        if (root != null) {
            for (AccessibilityWindowInfo window : list) {
                if (window.getId() == root.getWindowId()) {
                    return window;
                }
            }
        }
        return null;
    }

    private void window(AccessibilityWindowInfo window, boolean tree) {
        windows++;
        json.beginObject();
        json.field("id", window.getId());
        json.field("type", windowType(window.getType()));
        json.field("layer", window.getLayer());
        json.optional("title", window.getTitle());
        if (Build.VERSION.SDK_INT >= 30) {
            json.field("displayId", window.getDisplayId());
        }
        window.getBoundsInScreen(rect);
        json.bounds("bounds", rect.left, rect.top, rect.right, rect.bottom);
        json.field("active", window.isActive());
        json.field("focused", window.isFocused());
        json.flag("pictureInPicture", window.isInPictureInPictureMode());
        if (tree) {
            trees++;
            AccessibilityNodeInfo root = window.getRoot();
            json.name("root");
            if (root == null) {
                json.nullValue();
            } else {
                keepHidden = hiddenByKeyboard(window, root);
                behindKeyboard = keyboardShown && window.getType() == AccessibilityWindowInfo.TYPE_APPLICATION ? window : null;
                keyboardRegion = null;
                coverRegion = null;
                node(root, 0);
                keepHidden = false;
                behindKeyboard = null;
            }
        }
        json.endObject();
    }

    /** A floating keyboard's window can mark the whole focused app as not visible to the user, though it is on screen. */
    private boolean hiddenByKeyboard(AccessibilityWindowInfo window, AccessibilityNodeInfo root) {
        return keyboardShown && window.getType() == AccessibilityWindowInfo.TYPE_APPLICATION && window.isActive()
                && window.isFocused() && !root.isVisibleToUser();
    }

    /** Android marks an app node the windows above wholly cover as not visible; with the keyboard among them it stays, marked so, as uiautomator lists it. */
    private boolean coveredByKeyboard(AccessibilityNodeInfo n) {
        if (behindKeyboard == null) {
            return false;
        }
        n.getBoundsInScreen(rect);
        if (rect.isEmpty()) {
            return false;
        }
        if (coverRegion == null) {
            readCovers();
        }
        return new Region(rect).op(keyboardRegion, Region.Op.INTERSECT) && !new Region(rect).op(coverRegion, Region.Op.DIFFERENCE);
    }

    /** What the keyboards, and every window above the one being written but an accessibility overlay, cover. */
    private void readCovers() {
        keyboardRegion = new Region();
        coverRegion = new Region();
        for (AccessibilityWindowInfo window : windowList) {
            if (window.getLayer() <= behindKeyboard.getLayer() || window.getType() == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY) {
                continue;
            }
            Region region = touchRegion(window);
            coverRegion.op(region, Region.Op.UNION);
            if (window.getType() == AccessibilityWindowInfo.TYPE_INPUT_METHOD) {
                keyboardRegion.op(region, Region.Op.UNION);
            }
        }
    }

    /** Where a window takes touches: its region from API 33, else the bounds around it. */
    private static Region touchRegion(AccessibilityWindowInfo window) {
        Region region = new Region();
        if (Build.VERSION.SDK_INT >= 33) {
            window.getRegionInScreen(region);
        } else {
            Rect bounds = new Rect();
            window.getBoundsInScreen(bounds);
            region.set(bounds);
        }
        return region;
    }

    /** Stands in for the window list when the platform returns none. */
    private void rootOnlyWindow(AccessibilityNodeInfo root) {
        windows++;
        trees++;
        json.beginObject();
        json.field("id", root.getWindowId());
        json.field("type", "application");
        json.field("layer", 0);
        root.getBoundsInScreen(rect);
        json.bounds("bounds", rect.left, rect.top, rect.right, rect.bottom);
        json.field("active", true);
        json.field("focused", true);
        json.name("root");
        node(root, 0);
        json.endObject();
    }

    /** Booleans are written only when they differ from the default: false, or true for enabled and visibleToUser. */
    @SuppressWarnings("deprecation")
    private void node(AccessibilityNodeInfo n, int depth) {
        int index = table.add(n);
        nodes++;
        if (depth > maxDepth) {
            maxDepth = depth;
        }
        json.beginObject();
        json.field("i", index);
        json.optional("class", n.getClassName());
        json.optional("package", n.getPackageName());
        json.optional("resourceId", n.getViewIdResourceName());
        json.optional("text", n.getText());
        json.optional("contentDescription", n.getContentDescription());
        json.optional("hint", n.getHintText());
        if (Build.VERSION.SDK_INT >= 30) {
            json.optional("stateDescription", n.getStateDescription());
        }
        Bundle extras = n.getExtras();
        if (extras != null && extras.containsKey(ROLE_DESCRIPTION_KEY)) {
            json.optional("roleDescription", extras.getCharSequence(ROLE_DESCRIPTION_KEY));
        }
        if (options.testTags) {
            json.optional("testTag", testTag(n));
        }
        n.getBoundsInScreen(rect);
        json.bounds("bounds", rect.left, rect.top, rect.right, rect.bottom);
        json.flag("checkable", n.isCheckable());
        json.flag("checked", n.isChecked());
        if (Build.VERSION.SDK_INT >= 36) {
            int state = n.getChecked();
            if (n.isCheckable() || state != AccessibilityNodeInfo.CHECKED_STATE_FALSE) {
                json.field("checkedState", checkedState(state));
            }
        }
        json.flag("clickable", n.isClickable());
        json.flag("longClickable", n.isLongClickable());
        if (!n.isEnabled()) {
            json.field("enabled", false);
        }
        json.flag("focusable", n.isFocusable());
        json.flag("focused", n.isFocused());
        json.flag("scrollable", n.isScrollable());
        json.flag("selected", n.isSelected());
        json.flag("editable", n.isEditable());
        json.flag("password", n.isPassword());
        json.flag("showingHint", n.isShowingHintText());
        if (!n.isVisibleToUser()) {
            json.field("visibleToUser", false);
        }
        AccessibilityNodeInfo.RangeInfo range = n.getRangeInfo();
        if (range != null) {
            json.name("rangeInfo");
            range(json, range);
        }
        children(n, depth);
        json.endObject();
    }

    private void children(AccessibilityNodeInfo n, int depth) {
        int count = n.getChildCount();
        if (count == 0) {
            return;
        }
        if (depth + 1 > MAX_DEPTH || nodes >= MAX_NODES) {
            truncated = true;
            json.field("childCount", count);
            return;
        }
        boolean open = false;
        for (int i = 0; i < count; i++) {
            if (nodes >= MAX_NODES) {
                truncated = true;
                break;
            }
            AccessibilityNodeInfo child = n.getChild(i);
            if (child == null) {
                continue;
            }
            if (options.visibleOnly && !keepHidden && !child.isVisibleToUser() && !coveredByKeyboard(child)) {
                skippedInvisible++;
                continue;
            }
            if (!open) {
                json.name("children").beginArray();
                open = true;
            }
            node(child, depth + 1);
        }
        if (open) {
            json.endArray();
        }
    }

    /** Compose fills its test tag only on request, so refresh just the nodes that advertise the key. */
    private String testTag(AccessibilityNodeInfo n) {
        List<String> available = n.getAvailableExtraData();
        if (available == null || !available.contains(COMPOSE_TEST_TAG_KEY)) {
            return null;
        }
        CharSequence tag = n.getExtras().getCharSequence(COMPOSE_TEST_TAG_KEY);
        if (tag == null) {
            testTagRefreshes++;
            if (n.refreshWithExtraData(COMPOSE_TEST_TAG_KEY, new Bundle())) {
                tag = n.getExtras().getCharSequence(COMPOSE_TEST_TAG_KEY);
            }
        }
        if (tag == null) {
            return null;
        }
        testTagsFound++;
        return tag.toString();
    }

    static void range(Json json, AccessibilityNodeInfo.RangeInfo range) {
        json.beginObject();
        json.field("type", rangeType(range.getType()));
        json.name("min").valueFloat(range.getMin());
        json.name("max").valueFloat(range.getMax());
        json.name("current").valueFloat(range.getCurrent());
        json.endObject();
    }

    static String windowType(int type) {
        switch (type) {
            case AccessibilityWindowInfo.TYPE_APPLICATION:
                return "application";
            case AccessibilityWindowInfo.TYPE_INPUT_METHOD:
                return "inputMethod";
            case AccessibilityWindowInfo.TYPE_SYSTEM:
                return "system";
            case AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY:
                return "accessibilityOverlay";
            case AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER:
                return "splitScreenDivider";
            case AccessibilityWindowInfo.TYPE_MAGNIFICATION_OVERLAY:
                return "magnificationOverlay";
            default:
                return "unknown-" + type;
        }
    }

    static String checkedState(int state) {
        switch (state) {
            case AccessibilityNodeInfo.CHECKED_STATE_FALSE:
                return "unchecked";
            case AccessibilityNodeInfo.CHECKED_STATE_TRUE:
                return "checked";
            case AccessibilityNodeInfo.CHECKED_STATE_PARTIAL:
                return "partial";
            default:
                return "unknown-" + state;
        }
    }

    static String rangeType(int type) {
        switch (type) {
            case AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_INT:
                return "int";
            case AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_FLOAT:
                return "float";
            case AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_PERCENT:
                return "percent";
            case 3:
                return "indeterminate";
            default:
                return "unknown-" + type;
        }
    }
}
