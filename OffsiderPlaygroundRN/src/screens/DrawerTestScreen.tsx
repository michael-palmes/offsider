import { useEffect, useRef, useState } from 'react';
import { StyleSheet, Switch, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, fixtureLog, FullPage, HeaderMarker, Readout, Screen, Target, useHardwareBack } from '../fixtures';

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

  useHardwareBack(pushed, () => setPushed(false));
  useHardwareBack(slowPushed, () => setSlowPushed(false));

  return (
    <View style={styles.root}>
      <View style={[styles.content, { transform: [{ translateX: open ? drawerWidth : 0 }] }]}>
        <Screen route="drawer-test">
          <View style={styles.body}>
            <Readout id="drawer-test-pressed" label={`Drawer Pressed: ${pressed}`} value={pressed} />
            <Readout id="drawer-test-state" label={`Drawer: ${open ? 'Open' : 'Closed'}`} value={open ? 'Open' : 'Closed'} />
            <Target
              id="drawer-test-toggle"
              label={open ? 'Close Drawer' : 'Open Drawer'}
              onPress={() => {
                fixtureLog('drawer-test', open ? 'close drawer' : 'open drawer');
                setOpen((current) => !current);
              }}
            />
            <Target id="drawer-test-page-chip" label="Page Chip" onPress={() => press('Page Chip')} style={styles.chip} />
            <Target id="drawer-test-push" label="Open Reminders" onPress={() => setPushed(true)} />
            <View style={styles.slowRow}>
              <Target id="drawer-test-slow-push" label="Open Slowly" onPress={openSlowly} style={styles.slowPush} />
              {opening > 0 && <Readout id="drawer-test-opening" label={`Opening ${opening}`} />}
            </View>
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
      </View>
      <View testID="drawer-test-drawer" style={[styles.drawer, { paddingTop: insets.top + 16 }]}>
        <HeaderMarker id="drawer-test-drawer-title" title="Side Drawer" />
        {drawerRows.map((row) => (
          <Target
            key={row}
            id={`drawer-test-row-${row.split(' ')[1].toLowerCase()}`}
            label={row}
            onPress={() => press(row)}
            style={styles.drawerRow}
            textStyle={styles.drawerRowText}
          />
        ))}
      </View>
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
    zIndex: -1,
    padding: 16,
    gap: 8,
    backgroundColor: colours.panel,
  },
  drawerRow: { height: 64, alignItems: 'flex-start', borderRadius: 0, backgroundColor: 'transparent' },
  drawerRowText: { color: colours.text, fontWeight: '400' },
});
