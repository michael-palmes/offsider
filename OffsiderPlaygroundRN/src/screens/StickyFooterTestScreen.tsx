import { useState } from 'react';
import { ScrollView, StyleSheet, Switch, useWindowDimensions, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, Readout, Screen, Target } from '../fixtures';

const rowHeight = 64;
const rows = Array.from({ length: 30 }, (_, index) => index + 1);

export function StickyFooterTestScreen() {
  const insets = useSafeAreaInsets();
  const { width } = useWindowDimensions();
  const [pressed, setPressed] = useState('None');
  const [floating, setFloating] = useState(false);
  const [switches, setSwitches] = useState<Record<number, boolean>>({});

  const toggle = (
    <Target
      id="sticky-footer-test-toggle-floating"
      label={floating ? 'Pin Footer' : 'Float Footer'}
      onPress={() => setFloating((current) => !current)}
      style={styles.toggle}
      textStyle={styles.toggleText}
    />
  );

  return (
    <Screen route="sticky-footer-test" headerRight={toggle}>
      <Readout
        id="sticky-footer-test-pressed"
        label={`Sticky Footer Pressed: ${pressed}`}
        value={pressed}
        style={styles.readout}
      />
      <View style={styles.body}>
        <ScrollView testID="sticky-footer-test-scroll-view" style={styles.scroll}>
          {rows.map((row) => (
            <View key={row} style={styles.row}>
              <Target
                id={`sticky-footer-test-row-${row}`}
                label={`Sticky Footer Row ${row}`}
                onPress={() => setPressed(`Row ${row}`)}
                style={styles.rowButton}
                textStyle={styles.rowText}
              />
              <Switch
                testID={`sticky-footer-test-switch-${row}`}
                accessibilityLabel={`Sticky Footer Switch ${row}`}
                value={switches[row] ?? false}
                onValueChange={(value) => setSwitches((current) => ({ ...current, [row]: value }))}
              />
            </View>
          ))}
        </ScrollView>
        <Target
          id="sticky-footer-test-footer"
          label="Sticky Footer Continue"
          onPress={() => setPressed('Footer')}
          style={[styles.footer, floating ? [styles.floating, { bottom: insets.bottom + 8 }] : { marginBottom: insets.bottom + 8 }]}
        />
        <View testID="sticky-footer-test-drawer" style={[styles.drawer, { width, transform: [{ translateX: width }] }]}>
          <Target id="sticky-footer-test-drawer-item" label="Sticky Footer Drawer Item" onPress={() => setPressed('Drawer')} />
        </View>
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  readout: {
    padding: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
  body: { flex: 1 },
  scroll: { flex: 1 },
  row: {
    height: rowHeight,
    flexDirection: 'row',
    alignItems: 'center',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
  rowButton: { flex: 1, height: rowHeight, alignItems: 'flex-start', borderRadius: 0, backgroundColor: colours.background },
  rowText: { color: colours.text, fontWeight: '400' },
  footer: { marginHorizontal: 16, marginTop: 8 },
  floating: { position: 'absolute', left: 0, right: 0 },
  drawer: { position: 'absolute', top: 0, bottom: 0, padding: 16, backgroundColor: colours.panel },
  toggle: { minHeight: 32, height: 32, paddingHorizontal: 10, borderRadius: 7, backgroundColor: colours.panel },
  toggleText: { fontSize: 13, color: colours.text },
});
