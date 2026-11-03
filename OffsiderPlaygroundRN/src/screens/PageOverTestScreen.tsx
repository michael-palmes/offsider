import { useEffect, useState } from 'react';
import { Modal, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { BackButton, colours, fixtureLog, HeaderMarker, Readout, Target, useHardwareBack } from '../fixtures';

const pageRows = Array.from({ length: 40 }, (_, index) => `Choice ${index + 1}`);
const feedRows = Array.from({ length: 12 }, (_, index) => `Feed Item ${index + 1}`);
const denseTiles = Array.from({ length: 300 }, (_, index) => `Tile ${index + 1}`);
const nextLower: Record<Lower, Lower> = { feed: 'gallery', gallery: 'dense', dense: 'feed' };

type Lower = 'feed' | 'gallery' | 'dense';
// Last drawn after the lower screen; bare the same with no footer, so its list is the size of the feed; raised drawn first and lifted by zIndex; modal in React Native's Modal.
type PageMode = 'none' | 'last' | 'bare' | 'raised' | 'modal';

export function PageOverTestScreen() {
  const insets = useSafeAreaInsets();
  const [lower, setLower] = useState<Lower>('feed');
  const [mode, setMode] = useState<PageMode>('none');
  const [pressed, setPressed] = useState('None');

  const press = (what: string) => {
    fixtureLog('page-over-test', `pressed ${what}`);
    setPressed(what);
  };
  const open = (next: PageMode) => {
    fixtureLog('page-over-test', `open page ${next}`);
    setMode(next);
  };
  const close = () => {
    fixtureLog('page-over-test', 'close page');
    setMode('none');
  };

  useHardwareBack(mode !== 'none', close);

  useEffect(() => {
    if (__DEV__) {
      require('expo-dev-client').registerDevMenuItems([
        { name: 'Open Choices Page', callback: () => setMode('last'), shouldCollapse: true },
      ]);
    }
  }, []);

  const page = (
    <View testID={lower === 'gallery' ? undefined : 'page-over-page'} style={[styles.page, mode === 'raised' && styles.raised]}>
      <View style={[styles.pageHeader, { paddingTop: insets.top }]}>
        <Target id="page-over-back" label="Back" onPress={close} style={styles.back} textStyle={styles.backText} />
        <HeaderMarker id="page-over-title" title="Choices" style={styles.title} />
        <View style={styles.back} />
      </View>
      <ScrollView testID="page-over-page-list" style={styles.fill}>
        <Readout id="page-over-page-pressed" label={`Picked: ${pressed}`} style={styles.row} />
        {pageRows.map((row, index) => (
          <Target
            key={row}
            id={`page-over-${row.toLowerCase().replace(' ', '-')}`}
            label={row}
            onPress={() => press(row)}
            // Over the gallery, a gap in the rows leaves its middle under nothing labelled.
            style={[styles.pageRow, lower === 'gallery' && index === 5 && styles.gap]}
            textStyle={styles.pageRowText}
          />
        ))}
      </ScrollView>
      {mode !== 'bare' && (
        <View style={[styles.footer, { paddingBottom: insets.bottom + 8 }]}>
          <Target id="page-over-page-confirm" label="Confirm" onPress={() => press('Page Confirm')} />
        </View>
      )}
    </View>
  );

  const controls = (
    <>
      <Readout id="page-over-pressed" label={`Pressed: ${pressed}`} style={styles.row} />
      <View style={styles.actions}>
        <Target id="page-over-open" label="Open Page" onPress={() => open('last')} style={styles.action} />
        <Target id="page-over-open-raised" label="Open Raised" onPress={() => open('raised')} style={styles.action} />
        <Target id="page-over-open-modal" label="Open Modal" onPress={() => open('modal')} style={styles.action} />
        <Target id="page-over-open-bare" label="Open Bare" onPress={() => open('bare')} style={styles.action} />
      </View>
      <Target
        id="page-over-lower"
        label={`Lower: ${lower}`}
        onPress={() => setLower((current) => nextLower[current])}
        style={styles.lowerToggle}
      />
    </>
  );

  return (
    <View style={styles.root}>
      {mode === 'raised' && page}
      <View testID="page-over-home" style={styles.fill}>
        <View style={[styles.homeHeader, { paddingTop: insets.top }]}>
          <BackButton />
          <Target id="page-over-drawer" label="Open Drawer" onPress={() => press('Open Drawer')} style={styles.menu} textStyle={styles.menuText} />
          <HeaderMarker id="page-over-test-screen" title="Page Over" style={styles.title} />
        </View>
        {lower === 'feed' ? (
          <ScrollView testID="page-over-feed" style={styles.fill} contentContainerStyle={{ paddingBottom: insets.bottom + 60 }}>
            {controls}
            <View accessible accessibilityLabel="Try the planner. Learn more" style={styles.card}>
              <Text importantForAccessibility="no" style={styles.cardText}>
                Try the planner
              </Text>
            </View>
            {feedRows.map((row) => (
              <Readout key={row} id={`page-over-${row.toLowerCase().replace(/ /g, '-')}`} label={row} style={styles.row} />
            ))}
          </ScrollView>
        ) : lower === 'dense' ? (
          <View style={styles.fill}>
            {controls}
            <View testID="page-over-dense" style={styles.dense}>
              {denseTiles.map((tile) => (
                <Readout key={tile} id={`page-over-${tile.toLowerCase().replace(' ', '-')}`} label={tile} style={styles.tile} textStyle={styles.tileText} />
              ))}
            </View>
          </View>
        ) : (
          <View style={styles.fill}>
            {controls}
            <View testID="page-over-gallery" style={styles.fill}>
              <View testID="page-over-strip" style={styles.fill}>
                <View testID="page-over-panel" style={styles.fill}>
                  <Readout id="page-over-panel-title" label="Panel Title" style={styles.row} />
                  <Readout id="page-over-panel-body" label="Panel Body" style={styles.row} />
                </View>
              </View>
              <Readout id="page-over-position" label="Panel 1 of 3" style={styles.row} />
            </View>
          </View>
        )}
        <View style={[styles.tabs, { paddingBottom: insets.bottom }]}>
          <Target id="page-over-tab-home" label="Home" onPress={() => press('Home')} style={styles.tab} textStyle={styles.tabText} />
          <Target id="page-over-home-confirm" label="Confirm" onPress={() => press('Home Confirm')} style={styles.tab} />
        </View>
      </View>
      {(mode === 'last' || mode === 'bare') && page}
      <Modal visible={mode === 'modal'} onRequestClose={close}>
        {page}
      </Modal>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colours.background },
  fill: { flex: 1 },
  page: { ...StyleSheet.absoluteFill, backgroundColor: colours.background },
  raised: { zIndex: 10 },
  pageHeader: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 8 },
  homeHeader: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 8 },
  back: { width: 72, height: 44, paddingHorizontal: 8, backgroundColor: 'transparent' },
  backText: { color: colours.accent },
  menu: { width: 96, height: 44, paddingHorizontal: 4 },
  menuText: { fontSize: 13 },
  title: { flex: 1 },
  row: { padding: 12 },
  pageRow: { height: 48, marginHorizontal: 12, marginVertical: 2, backgroundColor: colours.panel },
  pageRowText: { color: colours.text },
  gap: { marginBottom: 160 },
  footer: { paddingHorizontal: 16, paddingTop: 8, backgroundColor: colours.panel },
  actions: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, paddingHorizontal: 12 },
  action: { minWidth: 110, paddingHorizontal: 4 },
  lowerToggle: { margin: 12 },
  card: { margin: 12, padding: 24, borderRadius: 12, backgroundColor: colours.panel },
  cardText: { fontSize: 17, color: colours.text },
  dense: { flex: 1, flexDirection: 'row', flexWrap: 'wrap', overflow: 'hidden' },
  tile: { width: 26, height: 22 },
  tileText: { fontSize: 5 },
  tabs: { flexDirection: 'row', gap: 8, paddingHorizontal: 8, paddingTop: 8, backgroundColor: colours.panel, position: 'absolute', left: 0, right: 0, bottom: 0 },
  tab: { flex: 1 },
  tabText: { color: '#FFFFFF' },
});
