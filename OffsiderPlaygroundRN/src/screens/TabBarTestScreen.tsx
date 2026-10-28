import { useState } from 'react';
import { Platform, ScrollView, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, fixtureLog, Readout, Screen, Target } from '../fixtures';

const tabs = ['Home', 'Saved'] as const;
type Tab = (typeof tabs)[number];
const rowHeight = 56;
const tabBarHeight = 49;
const footerHeight = 72;
const rows = Array.from({ length: 14 }, (_, index) => index + 1);

export function TabBarTestScreen() {
  const insets = useSafeAreaInsets();
  const [tab, setTab] = useState<Tab>('Home');
  const [pressed, setPressed] = useState('None');
  const [footer, setFooter] = useState(false);

  const press = (what: string) => {
    fixtureLog('tab-bar-test', `pressed ${what}`);
    setPressed(what);
  };

  const footerToggle = (
    <Target
      id="tab-bar-test-toggle-footer"
      label={footer ? 'Hide Footer' : 'Show Footer'}
      onPress={() => setFooter((current) => !current)}
      style={styles.toggle}
      textStyle={styles.toggleText}
    />
  );

  return (
    <Screen route="tab-bar-test" headerRight={footerToggle}>
      <Readout id="tab-bar-test-pressed" label={`Tab Bar Pressed: ${pressed}`} value={pressed} style={styles.readout} />
      <View style={styles.panes}>
        {tabs.map((item) => {
          const active = item === tab;
          const key = item.toLowerCase();
          return (
            <View key={item} testID={`tab-bar-test-pane-${key}`} style={[styles.pane, { zIndex: active ? 1 : 0 }]}>
              <ScrollView testID={`tab-bar-test-list-${key}`}>
                {rows.map((row) => (
                  <Target
                    key={row}
                    id={`tab-bar-test-${key}-row-${row}`}
                    label={`${item} Row ${row}`}
                    onPress={() => press(`${item} Row ${row}`)}
                    style={styles.row}
                    textStyle={styles.rowText}
                  />
                ))}
              </ScrollView>
            </View>
          );
        })}
        {footer && (
          <View style={[styles.footer, { bottom: tabBarHeight + insets.bottom }]}>
            <Target id="tab-bar-test-footer-action" label="Footer Action" onPress={() => press('Footer Action')} style={styles.footerAction} />
          </View>
        )}
        <View
          testID="tab-bar-test-tab-bar"
          accessibilityRole={Platform.OS === 'ios' ? 'tabbar' : 'tablist'}
          style={[styles.tabBar, { paddingBottom: insets.bottom }]}
        >
          {tabs.map((item) => (
            <Target
              key={item}
              id={`tab-bar-test-tab-${item.toLowerCase()}`}
              label={`${item} Tab`}
              role={Platform.OS === 'ios' ? 'button' : 'tab'}
              state={{ selected: tab === item }}
              onPress={() => {
                press(`${item} Tab`);
                setTab(item);
              }}
              style={styles.tab}
              textStyle={[styles.tabText, tab === item && styles.tabTextSelected]}
            />
          ))}
        </View>
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  readout: { padding: 16, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colours.separator },
  panes: { flex: 1 },
  pane: { ...StyleSheet.absoluteFill, backgroundColor: colours.background },
  row: { height: rowHeight, alignItems: 'flex-start', borderRadius: 0, backgroundColor: colours.background },
  rowText: { color: colours.text, fontWeight: '400' },
  footer: {
    position: 'absolute',
    left: 0,
    right: 0,
    height: footerHeight,
    zIndex: 2,
    alignItems: 'flex-end',
    justifyContent: 'center',
    paddingHorizontal: 16,
    backgroundColor: colours.panel,
  },
  footerAction: { width: 120 },
  tabBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    zIndex: 2,
    flexDirection: 'row',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colours.separator,
    backgroundColor: colours.panel,
  },
  tab: { flex: 1, height: tabBarHeight, borderRadius: 0, backgroundColor: 'transparent' },
  tabText: { fontSize: 15, fontWeight: '500', color: colours.secondary },
  tabTextSelected: { color: colours.accent, fontWeight: '700' },
  toggle: { minHeight: 32, height: 32, paddingHorizontal: 10, borderRadius: 7, backgroundColor: colours.panel },
  toggleText: { fontSize: 13, color: colours.text },
});
