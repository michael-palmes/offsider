import { useEffect, useRef, useState } from 'react';
import { LogBox, Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, fixtureLog, Readout, Screen, Target } from '../fixtures';

const tabs = ['Home', 'Search', 'Profile'] as const;
type Tab = (typeof tabs)[number];

const tabBarHeight = 49;
const scrimMs = 4000;
const bannerLabel = 'Connection lost. Can’t reach the server.';
// clearAllLogs exists at runtime but is missing from React Native's LogBox typings.
const logBox = LogBox as typeof LogBox & { clearAllLogs: () => void };

export function OverlayTestScreen() {
  const insets = useSafeAreaInsets();
  const [tab, setTab] = useState<Tab>('Home');
  const [banner, setBanner] = useState(false);
  const [scrim, setScrim] = useState(false);
  const [swallowed, setSwallowed] = useState(0);
  const [hiddenTaps, setHiddenTaps] = useState(0);
  const warnings = useRef(0);
  const scrimTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (scrimTimer.current) {
        clearTimeout(scrimTimer.current);
      }
    },
    [],
  );

  const swallow = (source: string) => {
    fixtureLog('overlay-test', `${source} swallowed a tap`);
    setSwallowed((current) => current + 1);
  };

  const showScrim = () => {
    fixtureLog('overlay-test', 'show scrim');
    setScrim(true);
    if (scrimTimer.current) {
      clearTimeout(scrimTimer.current);
    }
    scrimTimer.current = setTimeout(() => {
      scrimTimer.current = null;
      fixtureLog('overlay-test', 'hide scrim');
      setScrim(false);
    }, scrimMs);
  };

  return (
    <Screen route="overlay-test">
      <ScrollView style={styles.scroll} contentContainerStyle={styles.body}>
        <Readout id="overlay-test-tab" label={`Overlay Tab: ${tab}`} value={tab} />
        <Readout id="overlay-test-swallowed" label={`Swallowed Taps: ${swallowed}`} value={String(swallowed)} />
        <Readout id="overlay-test-scrim" label={`Scrim: ${scrim ? 'Shown' : 'Hidden'}`} />
        <Readout id="overlay-test-hidden-taps" label={`Hidden Taps: ${hiddenTaps}`} value={String(hiddenTaps)} />
        <Target
          id="overlay-test-toggle-banner"
          label={banner ? 'Hide Banner' : 'Show Banner'}
          onPress={() => {
            fixtureLog('overlay-test', banner ? 'hide banner' : 'show banner');
            setBanner((current) => !current);
          }}
        />
        <Target id="overlay-test-show-scrim" label="Show Silent Scrim" onPress={showScrim} />
        <View style={styles.hiddenArea}>
          <View
            testID="overlay-test-hidden-frame"
            accessible
            accessibilityLabel="Hidden Action Area"
            style={[styles.hiddenFrame, { pointerEvents: 'none' }]}
          >
            <Text importantForAccessibility="no" style={styles.hiddenFrameText}>
              Hidden Action Area
            </Text>
          </View>
          <View
            accessibilityElementsHidden
            importantForAccessibility="no-hide-descendants"
            style={StyleSheet.absoluteFill}
          >
            <Pressable
              testID="overlay-test-hidden-action"
              onPress={() => {
                fixtureLog('overlay-test', 'hidden action pressed');
                setHiddenTaps((current) => current + 1);
              }}
              style={({ pressed }) => [styles.hiddenAction, pressed && styles.pressed]}
            />
          </View>
        </View>
        <Target
          id="overlay-test-log-warning"
          label="Log Warning"
          onPress={() => {
            warnings.current += 1;
            fixtureLog('overlay-test', `log warning ${warnings.current}`);
            console.warn(`OffsiderFixture warning ${warnings.current}`);
          }}
        />
        <Target
          id="overlay-test-clear-logs"
          label="Clear Logs"
          onPress={() => {
            fixtureLog('overlay-test', 'clear logs');
            logBox.clearAllLogs();
          }}
        />
      </ScrollView>
      <View
        testID="overlay-test-tab-bar"
        accessibilityRole={Platform.OS === 'ios' ? 'tabbar' : 'tablist'}
        style={[styles.tabBar, { paddingBottom: insets.bottom }]}
      >
        {tabs.map((item) => (
          <Target
            key={item}
            id={`overlay-test-tab-${item.toLowerCase()}`}
            label={item}
            role={Platform.OS === 'ios' ? 'button' : 'tab'}
            state={{ selected: tab === item }}
            onPress={() => {
              fixtureLog('overlay-test', `tab ${item}`);
              setTab(item);
            }}
            style={styles.tab}
            textStyle={[styles.tabText, tab === item && styles.tabTextSelected]}
          />
        ))}
      </View>
      {banner && (
        <View
          testID="overlay-test-banner"
          accessible
          accessibilityLabel={bannerLabel}
          onStartShouldSetResponder={() => true}
          onResponderRelease={() => swallow('banner')}
          style={[styles.banner, { height: tabBarHeight + insets.bottom + 24, paddingBottom: insets.bottom }]}
        >
          <Text importantForAccessibility="no" style={styles.bannerText}>
            {bannerLabel}
          </Text>
        </View>
      )}
      {scrim && (
        <View
          accessibilityElementsHidden
          importantForAccessibility="no-hide-descendants"
          onStartShouldSetResponder={() => true}
          onResponderRelease={() => swallow('scrim')}
          style={styles.scrim}
        />
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1 },
  body: { padding: 16, gap: 12, alignItems: 'center' },
  hiddenArea: { width: 240, height: 56 },
  hiddenFrame: {
    ...StyleSheet.absoluteFill,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 10,
    borderWidth: 1,
    borderStyle: 'dashed',
    borderColor: colours.accent,
    backgroundColor: colours.panel,
  },
  hiddenFrameText: { fontSize: 15, color: colours.secondary },
  hiddenAction: { flex: 1, borderRadius: 10 },
  pressed: { backgroundColor: 'rgba(0,122,255,0.2)' },
  tabBar: {
    flexDirection: 'row',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colours.separator,
    backgroundColor: colours.panel,
  },
  tab: { flex: 1, height: tabBarHeight, borderRadius: 0, backgroundColor: 'transparent' },
  tabText: { fontSize: 15, fontWeight: '500', color: colours.secondary },
  tabTextSelected: { color: colours.accent, fontWeight: '700' },
  banner: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 16,
    backgroundColor: '#B3261E',
  },
  bannerText: { fontSize: 15, fontWeight: '600', color: '#FFFFFF', textAlign: 'center' },
  scrim: { ...StyleSheet.absoluteFill, backgroundColor: 'rgba(0,0,0,0.35)' },
});
