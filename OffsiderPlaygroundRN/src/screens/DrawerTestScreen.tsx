import { useEffect, useRef, useState } from 'react';
import { Animated, Easing, Platform, Pressable, StyleSheet, Switch, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  colours,
  fixtureLog,
  FullPage,
  HeaderMarker,
  hiddenFromAccessibility,
  Readout,
  Screen,
  screenReaderOn,
  SlidePage,
  Target,
  useHardwareBack,
} from '../fixtures';

const drawerWidth = 280;
const drawerRows = ['Drawer Inbox', 'Drawer Reminders', 'Drawer Archive'] as const;
// Longer than one verify window and its screenshots, so a second tap would land before the page.
const slowPushDelay = 4500;
// A loader that ticks faster than a tree read and is gone before the verify window ends, so it never settles.
const openingTick = 100;
const openingTicks = 12;

export function DrawerTestScreen() {
  const insets = useSafeAreaInsets();
  const [open, setOpen] = useState(false);
  const [pushed, setPushed] = useState(false);
  const [pressed, setPressed] = useState('None');
  const [quiet, setQuiet] = useState(true);
  const [slowPresses, setSlowPresses] = useState(0);
  const [opening, setOpening] = useState(0);
  const [slowPushed, setSlowPushed] = useState(false);
  const [above, setAbove] = useState(false);
  const [rowPage, setRowPage] = useState({ mounted: false, open: false });
  const [confirm, setConfirm] = useState(false);
  // Follows the confirm panel only while a screen reader runs, so without one the panel on screen stays hidden.
  const [confirmExposed, setConfirmExposed] = useState(false);
  const slide = useRef(new Animated.Value(0)).current;
  const confirmSlide = useRef(new Animated.Value(0)).current;
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);

  useEffect(() => () => timers.current.forEach(clearTimeout), []);

  const openSlowly = () => {
    fixtureLog('drawer-test', 'slow push pressed');
    setSlowPresses((current) => current + 1);
    for (let tick = 1; tick <= openingTicks; tick += 1) {
      timers.current.push(setTimeout(() => setOpening(tick < openingTicks ? tick : 0), tick * openingTick));
    }
    timers.current.push(setTimeout(() => setSlowPushed(true), slowPushDelay));
  };

  const press = (what: string) => {
    fixtureLog('drawer-test', `pressed ${what}`);
    setPressed(what);
  };

  const showConfirm = (next: boolean) => {
    fixtureLog('drawer-test', next ? 'confirm panel in' : 'confirm panel out');
    setConfirm(next);
    if (screenReaderOn()) {
      setConfirmExposed(next);
    }
    Animated.timing(confirmSlide, { toValue: next ? 1 : 0, duration: 300, easing: Easing.inOut(Easing.cubic), useNativeDriver: true }).start();
  };

  const setDrawer = (next: boolean) => {
    fixtureLog('drawer-test', next ? 'open drawer' : 'close drawer');
    setOpen(next);
    if (!above) {
      return;
    }
    if (!next && confirm) {
      showConfirm(false);
    }
    Animated.timing(slide, {
      toValue: next ? drawerWidth : 0,
      duration: 200,
      easing: Easing.inOut(Easing.sin),
      useNativeDriver: Platform.OS === 'android',
    }).start();
  };

  const drawerBack = () => (confirm ? showConfirm(false) : setDrawer(false));

  useHardwareBack(above && open && !rowPage.open, drawerBack);
  useHardwareBack(rowPage.open, () => setRowPage({ mounted: true, open: false }));
  useHardwareBack(pushed, () => setPushed(false));
  useHardwareBack(slowPushed, () => setSlowPushed(false));

  const content = (
    <>
      <Screen route="drawer-test">
        <View style={styles.body}>
          <Readout id="drawer-test-pressed" label={`Drawer Pressed: ${pressed}`} value={pressed} />
          <Readout id="drawer-test-state" label={`Drawer: ${open ? 'Open' : 'Closed'}`} value={open ? 'Open' : 'Closed'} />
          <Target
            id="drawer-test-toggle"
            label={open ? 'Close Drawer' : 'Open Drawer'}
            onPress={() => setDrawer(!open)}
          />
          <Target id="drawer-test-page-chip" label="Page Chip" onPress={() => press('Page Chip')} style={styles.chip} />
          <Target id="drawer-test-push" label="Open Reminders" onPress={() => setPushed(true)} />
          <View style={styles.slowRow}>
            <Target id="drawer-test-slow-push" label="Open Slowly" onPress={openSlowly} style={styles.slowPush} />
            {opening > 0 && <Readout id="drawer-test-opening" label={`Opening ${opening}`} />}
          </View>
          <Target
            id="drawer-test-layer"
            label={`Drawer Layer: ${above ? 'Above' : 'Beneath'}`}
            disabled={open}
            onPress={() => {
              fixtureLog('drawer-test', `drawer layer ${above ? 'beneath' : 'above'}`);
              setAbove((current) => !current);
            }}
            style={styles.layer}
            textStyle={styles.layerText}
          />
        </View>
      </Screen>
      {pushed && (
        <FullPage
          id="drawer-test-pushed"
          backId="drawer-test-pushed-back"
          titleId="drawer-test-pushed-title"
          title="Reminders"
          onBack={() => setPushed(false)}
        >
          <View style={styles.pushedBody}>
            <Target id="drawer-test-pushed-reminders" label="Drawer Reminders" onPress={() => press('Pushed Reminders')} />
            <View style={styles.switchRow}>
              <Readout id="drawer-test-quiet-label" label="Quiet Hours" />
              <Switch
                testID="drawer-test-quiet"
                accessibilityLabel="Quiet Hours"
                value={quiet}
                onValueChange={(value) => {
                  fixtureLog('drawer-test', `quiet hours ${value ? 'on' : 'off'}`);
                  setQuiet(value);
                }}
              />
            </View>
          </View>
        </FullPage>
      )}
      {slowPushed && (
        <FullPage
          id="drawer-test-slow"
          backId="drawer-test-slow-back"
          titleId="drawer-test-slow-title"
          title="Slow Page"
          onBack={() => setSlowPushed(false)}
        >
          <View style={styles.pushedBody}>
            <Readout id="drawer-test-slow-presses" label={`Slow Presses: ${slowPresses}`} value={String(slowPresses)} />
            <Target id="drawer-test-slow-row" label="Slow Page Row" onPress={() => press('Slow Page Row')} />
          </View>
        </FullPage>
      )}
    </>
  );

  const rows = drawerRows.map((row) => (
    <Target
      key={row}
      id={`drawer-test-row-${row.split(' ')[1].toLowerCase()}`}
      label={row}
      onPress={() => (above && row === 'Drawer Reminders' ? setRowPage({ mounted: true, open: true }) : press(row))}
      style={styles.drawerRow}
      textStyle={styles.drawerRowText}
    />
  ));

  if (!above) {
    return (
      <View style={styles.root}>
        <View style={[styles.content, { transform: [{ translateX: open ? drawerWidth : 0 }] }]}>{content}</View>
        <View testID="drawer-test-drawer" style={[styles.drawer, styles.drawerBeneath, { paddingTop: insets.top + 16 }]}>
          <HeaderMarker id="drawer-test-drawer-title" title="Side Drawer" />
          {rows}
        </View>
      </View>
    );
  }

  return (
    <View style={styles.root}>
      <Animated.View {...hiddenFromAccessibility(open)} style={[styles.content, { transform: [{ translateX: slide }] }]}>
        {content}
      </Animated.View>
      <Animated.View
        style={[
          styles.scrim,
          { pointerEvents: open ? 'auto' : 'none', opacity: slide.interpolate({ inputRange: [0, drawerWidth], outputRange: [0, 0.5] }) },
        ]}
      >
        <Pressable accessible={false} style={StyleSheet.absoluteFill} onPress={() => setDrawer(false)} />
      </Animated.View>
      <Animated.View
        testID="drawer-test-drawer"
        {...hiddenFromAccessibility(!open)}
        style={[
          styles.drawer,
          { paddingTop: insets.top + 16, transform: [{ translateX: Animated.subtract(slide, drawerWidth) }] },
        ]}
      >
        <View style={styles.drawerHeader}>
          <Target id="drawer-test-drawer-back" label="Back" onPress={drawerBack} style={styles.drawerBack} textStyle={styles.drawerBackText} />
          <HeaderMarker id="drawer-test-drawer-title" title="Side Drawer" />
        </View>
        <View style={styles.drawerBody}>
          <Animated.View
            {...hiddenFromAccessibility(confirmExposed)}
            style={[
              styles.drawerList,
              { transform: [{ translateX: confirmSlide.interpolate({ inputRange: [0, 1], outputRange: [0, -drawerWidth] }) }] },
            ]}
          >
            {rows}
            <Target
              id="drawer-test-row-reset"
              label="Reset Drawer"
              onPress={() => showConfirm(true)}
              style={styles.drawerRow}
              textStyle={styles.drawerRowText}
            />
          </Animated.View>
          <Animated.View
            {...hiddenFromAccessibility(!confirmExposed)}
            style={[
              styles.drawerConfirm,
              { transform: [{ translateX: confirmSlide.interpolate({ inputRange: [0, 1], outputRange: [drawerWidth, 0] }) }] },
            ]}
          >
            <HeaderMarker id="drawer-test-confirm-title" title="Reset the drawer?" />
            <Target
              id="drawer-test-confirm-reset"
              label="Reset Drawer"
              onPress={() => {
                press('Confirm Reset');
                showConfirm(false);
              }}
            />
            <Target id="drawer-test-confirm-cancel" label="Cancel" onPress={() => showConfirm(false)} style={styles.cancel} textStyle={styles.cancelText} />
          </Animated.View>
        </View>
      </Animated.View>
      {rowPage.mounted && (
        <SlidePage kind="left" open={rowPage.open} top onClosed={() => setRowPage({ mounted: false, open: false })}>
          <FullPage
            id="drawer-test-row-page"
            backId="drawer-test-row-page-back"
            titleId="drawer-test-row-page-title"
            title="Reminders"
            onBack={() => setRowPage({ mounted: true, open: false })}
          >
            <View style={styles.pushedBody}>
              <Target id="drawer-test-row-page-reminders" label="Drawer Reminders" onPress={() => press('Row Page Reminders')} />
            </View>
          </FullPage>
        </SlidePage>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  content: { flex: 1, backgroundColor: colours.background },
  body: { padding: 16, gap: 16 },
  chip: { alignSelf: 'flex-start', width: 160 },
  slowRow: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  slowPush: { width: 160 },
  pushedBody: { padding: 16, gap: 16 },
  switchRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 64 },
  drawer: {
    position: 'absolute',
    top: 0,
    bottom: 0,
    left: 0,
    width: drawerWidth,
    padding: 16,
    gap: 8,
    backgroundColor: colours.panel,
  },
  drawerBeneath: { zIndex: -1 },
  layer: { alignSelf: 'flex-start', backgroundColor: colours.panel },
  layerText: { color: colours.accent, fontSize: 15 },
  scrim: { ...StyleSheet.absoluteFill, backgroundColor: '#000000' },
  drawerHeader: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  drawerBack: { paddingHorizontal: 8, backgroundColor: 'transparent' },
  drawerBackText: { color: colours.accent },
  drawerBody: { flex: 1, overflow: 'hidden' },
  drawerList: { gap: 8 },
  drawerConfirm: { ...StyleSheet.absoluteFill, gap: 16, backgroundColor: colours.panel },
  cancel: { backgroundColor: 'transparent' },
  cancelText: { color: colours.accent },
  drawerRow: { height: 64, alignItems: 'flex-start', borderRadius: 0, backgroundColor: 'transparent' },
  drawerRowText: { color: colours.text, fontWeight: '400' },
});
