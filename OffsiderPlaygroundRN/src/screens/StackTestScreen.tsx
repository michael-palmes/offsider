import { useEffect, useRef, useState } from 'react';
import { Platform, StyleSheet, useWindowDimensions, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  colours,
  fixtureLog,
  FullPage,
  HeaderMarker,
  Readout,
  Screen,
  Target,
  useHardwareBack,
} from '../fixtures';

const maxDepth = 3;
const tabs = ['Home', 'Products'] as const;
type Tab = (typeof tabs)[number];
const tabRowHeight = 49;
const closeLaterMs = 800;

export function StackTestScreen() {
  const { width } = useWindowDimensions();
  const insets = useSafeAreaInsets();
  const [depth, setDepth] = useState(1);
  const [state, setState] = useState('Initial');
  const [hideInactive, setHideInactive] = useState(false);
  const [fullOffset, setFullOffset] = useState(false);
  const [tab, setTab] = useState<Tab>('Home');
  const [fullDepth, setFullDepth] = useState(0);
  const closeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const previousOffset = -width * (fullOffset ? 1 : 0.3);

  const cancelCloseLater = () => {
    if (closeTimer.current) {
      clearTimeout(closeTimer.current);
      closeTimer.current = null;
    }
  };

  useEffect(
    () => () => {
      if (closeTimer.current) {
        clearTimeout(closeTimer.current);
      }
    },
    [],
  );

  const next = () => {
    fixtureLog('stack-test', depth < maxDepth ? `push page ${depth + 1}` : 'next ignored at max depth');
    setDepth((current) => Math.min(current + 1, maxDepth));
  };

  const back = () => {
    fixtureLog('stack-test', depth > 1 ? `pop page ${depth}` : 'back ignored at first page');
    setDepth((current) => Math.max(current - 1, 1));
  };

  const mark = (page: number) => {
    fixtureLog('stack-test', `page ${page} marked`);
    setState(`Page ${page} marked`);
  };

  const popFull = (page: number) => {
    fixtureLog('stack-test', `pop full page ${page}`);
    if (page === 1) {
      cancelCloseLater();
    }
    setFullDepth(page - 1);
  };

  useHardwareBack(fullDepth > 0, () => popFull(fullDepth));

  const closeLater = () => {
    fixtureLog('stack-test', `close full page 1 in ${closeLaterMs} ms`);
    cancelCloseLater();
    closeTimer.current = setTimeout(() => {
      closeTimer.current = null;
      fixtureLog('stack-test', 'pop full page 1 (late)');
      setFullDepth(0);
    }, closeLaterMs);
  };

  return (
    <View style={styles.root}>
      <Screen route="stack-test">
        <View style={styles.controls}>
          <Readout id="stack-test-state" label={`Stack State: ${state}`} value={state} />
          <Readout id="stack-test-depth" label={`Stack Depth: ${depth}`} value={String(depth)} />
          <Readout id="stack-test-full-depth" label={`Full Page Depth: ${fullDepth}`} value={String(fullDepth)} />
          <View style={styles.toggles}>
            <Target
              id="stack-test-hide-inactive"
              label={`Hide Inactive Pages: ${hideInactive ? 'On' : 'Off'}`}
              onPress={() => {
                fixtureLog('stack-test', `hide inactive ${hideInactive ? 'off' : 'on'}`);
                setHideInactive((current) => !current);
              }}
              style={styles.toggle}
              textStyle={styles.toggleText}
            />
            <Target
              id="stack-test-offset"
              label={`Previous Offset: ${fullOffset ? '100%' : '30%'}`}
              onPress={() => {
                fixtureLog('stack-test', `previous offset ${fullOffset ? '30%' : '100%'}`);
                setFullOffset((current) => !current);
              }}
              style={styles.toggle}
              textStyle={styles.toggleText}
            />
          </View>
        </View>
        <View style={styles.stack}>
          {Array.from({ length: depth }, (_, index) => {
            const page = index + 1;
            const active = page === depth;
            return (
              <View
                key={page}
                accessibilityElementsHidden={!active && hideInactive}
                importantForAccessibility={!active && hideInactive ? 'no-hide-descendants' : 'auto'}
                style={[
                  styles.page,
                  { pointerEvents: active ? 'auto' : 'none', transform: [{ translateX: active ? 0 : previousOffset }] },
                ]}
              >
                <HeaderMarker id="stack-test-page-title" title={`Page ${page}`} style={styles.pageTitle} />
                <Readout id={`stack-test-page-${page}`} label={`On Page ${page}`} />
                <Target id="stack-test-next" label="Next Page" onPress={next} />
                <Target id="stack-test-mark" label="Mark Page" onPress={() => mark(page)} />
                <Target id="stack-test-back" label="Previous Page" onPress={back} />
              </View>
            );
          })}
        </View>
        <View style={styles.actionRow}>
          <Target
            id="stack-test-open-full"
            label="Open Full Page"
            onPress={() => {
              fixtureLog('stack-test', 'push full page 1');
              setFullDepth(1);
            }}
            style={styles.action}
          />
        </View>
        <View
          testID="stack-test-tab-bar"
          accessibilityRole={Platform.OS === 'ios' ? 'tabbar' : 'tablist'}
          style={[styles.tabRow, { paddingBottom: insets.bottom }]}
        >
          {tabs.map((item) => (
            <Target
              key={item}
              id={`stack-test-tab-${item.toLowerCase()}`}
              label={`${item} Tab`}
              role={Platform.OS === 'ios' ? 'button' : 'tab'}
              state={{ selected: tab === item }}
              onPress={() => {
                fixtureLog('stack-test', `tab ${item}`);
                setTab(item);
                setState(`Tab: ${item}`);
              }}
              style={styles.tab}
              textStyle={[styles.tabText, tab === item && styles.tabTextSelected]}
            />
          ))}
        </View>
      </Screen>
      {fullDepth >= 1 && (
        <FullPage
          id="stack-test-full-page-1"
          backId="stack-test-full-back-1"
          titleId="stack-test-full-title-1"
          title="Full Page"
          onBack={() => popFull(1)}
        >
          <View style={styles.fullBody}>
            <Target id="stack-test-full-close-later" label="Close Later" onPress={closeLater} />
          </View>
          <View style={styles.actionRow}>
            <Target
              id="stack-test-full-next"
              label="Open Flags"
              onPress={() => {
                fixtureLog('stack-test', 'push full page 2');
                setFullDepth(2);
              }}
              style={styles.action}
            />
          </View>
          <View style={[styles.tabRow, { paddingBottom: insets.bottom }]}>
            <View style={styles.tabCell} />
            <View style={[styles.tabCell, styles.buyCell]}>
              <Target
                id="stack-test-full-buy"
                label="Buy"
                onPress={() => {
                  fixtureLog('stack-test', 'buy pressed');
                  setState('Buy pressed');
                }}
                style={styles.buy}
              />
            </View>
          </View>
        </FullPage>
      )}
      {fullDepth >= 2 && (
        <FullPage
          id="stack-test-full-page-2"
          backId="stack-test-full-back-2"
          titleId="stack-test-full-title-2"
          title="Flags"
          onBack={() => popFull(2)}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  controls: {
    padding: 16,
    gap: 8,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
  toggles: { flexDirection: 'row', gap: 8 },
  toggle: { flex: 1, backgroundColor: colours.panel },
  toggleText: { color: colours.accent, fontSize: 15 },
  stack: { flex: 1 },
  page: {
    ...StyleSheet.absoluteFill,
    padding: 16,
    gap: 16,
    alignItems: 'center',
    backgroundColor: colours.background,
    borderLeftWidth: StyleSheet.hairlineWidth,
    borderLeftColor: colours.separator,
  },
  pageTitle: { alignSelf: 'stretch', paddingVertical: 12 },
  actionRow: {
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colours.separator,
  },
  action: { height: 44 },
  tabRow: {
    flexDirection: 'row',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colours.separator,
    backgroundColor: colours.panel,
  },
  tab: { flex: 1, height: tabRowHeight, borderRadius: 0, backgroundColor: 'transparent' },
  tabText: { fontSize: 15, fontWeight: '500', color: colours.secondary },
  tabTextSelected: { color: colours.accent, fontWeight: '700' },
  tabCell: { flex: 1, height: tabRowHeight },
  buyCell: { paddingLeft: 8, paddingRight: 16, paddingVertical: 2 },
  buy: { flex: 1 },
  fullBody: { flex: 1, padding: 16, gap: 16, alignItems: 'center' },
});
