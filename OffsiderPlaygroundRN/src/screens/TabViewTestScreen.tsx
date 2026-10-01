import { useState } from 'react';
import { Platform, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, Readout, Screen, Target } from '../fixtures';

const tabs = ['Home', 'Settings'] as const;
type Tab = (typeof tabs)[number];

export function TabViewTestScreen() {
  const insets = useSafeAreaInsets();
  const [selected, setSelected] = useState<Tab>('Home');

  return (
    <Screen route="tab-view-test">
      <View style={styles.body}>
        <Readout id="tab-view-test-title" label="TabView Playground" textStyle={styles.title} />
        <Readout id="tab-view-current-tab" label={`Current Tab: ${selected}`} value={selected} />
        {selected === 'Home' ? (
          <Readout id="tab-view-home-panel" label="Home panel active" />
        ) : (
          <Readout id="tab-view-settings-panel" label="Settings panel active" />
        )}
      </View>
      <View
        testID="tab-view-tab-bar"
        accessibilityRole={Platform.OS === 'ios' ? 'tabbar' : 'tablist'}
        style={[styles.tabBar, { paddingBottom: insets.bottom }]}
      >
        {tabs.map((tab) => (
          <Target
            key={tab}
            id={`tab-view-tab-${tab.toLowerCase()}`}
            label={tab}
            role={Platform.OS === 'ios' ? 'button' : 'tab'}
            state={{ selected: selected === tab }}
            onPress={() => setSelected(tab)}
            style={styles.tab}
            textStyle={[styles.tabText, selected === tab && styles.tabTextSelected]}
          />
        ))}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  body: { flex: 1, alignItems: 'center', padding: 16, gap: 16 },
  title: { fontSize: 20, fontWeight: '700' },
  tabBar: {
    flexDirection: 'row',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colours.separator,
    backgroundColor: colours.panel,
  },
  tab: { flex: 1, height: 49, borderRadius: 0, backgroundColor: 'transparent' },
  tabText: { fontSize: 15, fontWeight: '500', color: colours.secondary },
  tabTextSelected: { color: colours.accent, fontWeight: '700' },
});
