import { useState } from 'react';
import { Pressable, ScrollView, StyleSheet, TextInput, useWindowDimensions, View } from 'react-native';

import { colours, fixtureLog, HeaderMarker, Readout, Screen, Target } from '../fixtures';

const tabs = ['Home', 'Saved', 'Search'] as const;
type Tab = (typeof tabs)[number];
const rows = Array.from({ length: 12 }, (_, index) => index + 1);
const panelWidth = 280;

const hiddenFromAccessibility = { accessibilityElementsHidden: true, importantForAccessibility: 'no-hide-descendants' } as const;

export function GapTabsTestScreen() {
  const { width } = useWindowDimensions();
  const [tab, setTab] = useState<Tab>('Home');
  const [pressed, setPressed] = useState('None');
  const [panel, setPanel] = useState(false);
  const [page, setPage] = useState(false);

  const press = (what: string) => {
    fixtureLog('gap-tabs-test', `pressed ${what}`);
    setPressed(what);
  };

  const pane = (item: Tab) => ({
    style: [styles.pane, { transform: [{ translateX: (tabs.indexOf(item) - tabs.indexOf(tab)) * width }] }],
    ...(item === 'Home' ? {} : hiddenFromAccessibility),
  });

  const list = (item: Tab) => (
    <ScrollView testID={`gap-tabs-list-${item.toLowerCase()}`}>
      {rows.map((row) => (
        <Target
          key={row}
          id={`gap-tabs-${item.toLowerCase()}-row-${row}`}
          label={`${item} Item ${row}`}
          onPress={() => press(`${item} Item ${row}`)}
          style={styles.row}
          textStyle={styles.rowText}
        />
      ))}
    </ScrollView>
  );

  return (
    <View style={styles.root}>
      <View style={styles.root} {...(panel ? hiddenFromAccessibility : {})}>
        <Screen route="gap-tabs-test">
          <View style={styles.status}>
            <Readout id="gap-tabs-pressed" label={`Gap Pressed: ${pressed}`} value={pressed} style={styles.pressed} />
            <Target id="gap-tabs-open-panel" label="Open Panel" onPress={() => setPanel(true)} style={styles.open} />
            <Target id="gap-tabs-open-page" label="Open Page" onPress={() => setPage(true)} style={styles.open} />
          </View>
          <View style={styles.panes}>
            <View {...pane('Home')}>{list('Home')}</View>
            <View {...pane('Saved')}>{list('Saved')}</View>
            <View {...pane('Search')}>
              <View style={styles.search}>
                <TextInput testID="gap-tabs-search-field" accessibilityLabel="Find Items" placeholder="Find items" style={styles.field} />
                <TextInput testID="gap-tabs-passcode" accessibilityLabel="Item Passcode" defaultValue="4821-fixture" secureTextEntry style={styles.field} />
                <Readout id="gap-tabs-result" label="Item Number 4821 7730" />
              </View>
            </View>
          </View>
          <View style={styles.tabBar}>
            {tabs.map((item) => (
              <Target
                key={item}
                id={`gap-tabs-tab-${item.toLowerCase()}`}
                label={`${item} Tab`}
                state={{ selected: tab === item }}
                onPress={() => {
                  press(`${item} Tab`);
                  setTab(item);
                }}
                style={styles.tab}
                textStyle={styles.tabText}
              />
            ))}
          </View>
        </Screen>
      </View>
      {page && (
        <View style={styles.page} {...hiddenFromAccessibility}>
          <HeaderMarker id="gap-tabs-page-title" title="Hidden Page" />
          <Target id="gap-tabs-page-action" label="Page Action" onPress={() => press('Page Action')} />
          <Target id="gap-tabs-page-close" label="Close Page" onPress={() => setPage(false)} />
          <Readout id="gap-tabs-page-footer" label="Page Footer" style={styles.pageFooter} />
        </View>
      )}
      {panel && <Pressable accessible={false} style={styles.scrim} onPress={() => setPanel(false)} />}
      <View style={[styles.panel, { transform: [{ translateX: panel ? 0 : -panelWidth }] }]}>
        <Target id="gap-tabs-panel-back" label="Panel Back" onPress={() => setPanel(false)} />
        <View style={styles.panelBody} {...hiddenFromAccessibility}>
          <HeaderMarker id="gap-tabs-panel-title" title="Archive everything?" />
          <Target id="gap-tabs-panel-confirm" label="Archive All" onPress={() => press('Archive All')} />
          <Target id="gap-tabs-panel-cancel" label="Cancel Archive" onPress={() => setPanel(false)} />
        </View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  status: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', padding: 16, gap: 12 },
  pressed: { width: '100%' },
  open: { width: 120 },
  panes: { flex: 1, overflow: 'hidden' },
  pane: { ...StyleSheet.absoluteFill, backgroundColor: colours.background },
  row: { height: 56, alignItems: 'flex-start', borderRadius: 0, backgroundColor: colours.background },
  rowText: { color: colours.text, fontWeight: '400' },
  search: { padding: 16, gap: 16 },
  field: { height: 44, paddingHorizontal: 12, borderRadius: 8, backgroundColor: colours.panel, color: colours.text },
  page: { ...StyleSheet.absoluteFill, padding: 16, paddingTop: 80, gap: 16, backgroundColor: colours.background },
  pageFooter: { marginTop: 'auto', marginBottom: 32 },
  tabBar: { flexDirection: 'row', borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colours.separator, backgroundColor: colours.panel },
  tab: { flex: 1, height: 49, borderRadius: 0, backgroundColor: 'transparent' },
  tabText: { fontSize: 15, fontWeight: '500', color: colours.secondary },
  scrim: { ...StyleSheet.absoluteFill, backgroundColor: 'rgba(0, 0, 0, 0.4)' },
  panel: { position: 'absolute', top: 0, bottom: 0, left: 0, width: panelWidth, padding: 16, paddingTop: 80, gap: 16, backgroundColor: colours.panel },
  panelBody: { gap: 16 },
});
