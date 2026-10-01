package com.mpalmes.offsider.helper;

import android.content.res.Resources;
import android.util.DisplayMetrics;
import android.view.Display;

/** Reads display 0 from the hidden DisplayManagerGlobal, falling back to the system resources. */
final class DisplayProbe {
    private DisplayProbe() {
    }

    static void write(Json json) {
        String source;
        String fallbackReason = null;
        int width;
        int height;
        int rotation = -1;
        int density;
        Display.Mode mode = null;
        try {
            Class<?> global = Class.forName("android.hardware.display.DisplayManagerGlobal");
            Object instance = global.getMethod("getInstance").invoke(null);
            Object info = global.getMethod("getDisplayInfo", int.class).invoke(instance, 0);
            if (info == null) {
                throw new IllegalStateException("DisplayManagerGlobal has no DisplayInfo for display 0");
            }
            Class<?> type = info.getClass();
            width = type.getField("logicalWidth").getInt(info);
            height = type.getField("logicalHeight").getInt(info);
            rotation = type.getField("rotation").getInt(info);
            density = type.getField("logicalDensityDpi").getInt(info);
            mode = mode(type, info);
            source = "DisplayManagerGlobal";
        } catch (ReflectiveOperationException | RuntimeException e) {
            DisplayMetrics metrics = Resources.getSystem().getDisplayMetrics();
            width = metrics.widthPixels;
            height = metrics.heightPixels;
            rotation = -1;
            density = metrics.densityDpi;
            mode = null;
            source = "Resources.getSystem";
            fallbackReason = HelperFailure.describe(e);
        }
        json.name("display").beginObject();
        json.field("displayId", 0);
        json.field("source", source);
        json.optional("fallbackReason", fallbackReason);
        json.field("logicalWidthPx", width);
        json.field("logicalHeightPx", height);
        if (rotation >= 0) {
            json.field("rotation", rotation);
        }
        if (mode != null) {
            json.field("physicalWidthPx", mode.getPhysicalWidth());
            json.field("physicalHeightPx", mode.getPhysicalHeight());
        }
        json.field("densityDpi", density);
        json.field("densityStableDpi", DisplayMetrics.DENSITY_DEVICE_STABLE);
        json.endObject();
    }

    /** The active display mode, whose physical size ignores a wm size override. */
    private static Display.Mode mode(Class<?> type, Object info) {
        try {
            Object mode = type.getMethod("getMode").invoke(info);
            if (mode instanceof Display.Mode) {
                return (Display.Mode) mode;
            }
        } catch (ReflectiveOperationException | RuntimeException e) {
            // Older DisplayInfo layouts: look the mode up by id below.
        }
        try {
            int id = type.getField("modeId").getInt(info);
            Object modes = type.getField("supportedModes").get(info);
            if (modes instanceof Display.Mode[]) {
                for (Display.Mode mode : (Display.Mode[]) modes) {
                    if (mode.getModeId() == id) {
                        return mode;
                    }
                }
            }
        } catch (ReflectiveOperationException | RuntimeException e) {
            return null;
        }
        return null;
    }
}
