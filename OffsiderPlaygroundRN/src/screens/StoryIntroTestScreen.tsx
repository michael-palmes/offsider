import { useEffect, useRef, useState } from 'react';
import { Animated, Easing, type GestureResponderEvent, Pressable, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, fixtureLog, Readout, Target } from '../fixtures';
import { useNavigation } from '../navigation';

const pages = [
  { title: 'Track Parcels', body: 'Every parcel you send shows here with its latest stop.' },
  { title: 'Plan Routes', body: 'Group nearby stops into one run and save the drive.' },
  { title: 'Share Updates', body: 'Send a live link so people know when to expect you.' },
] as const;
const last = pages.length - 1;
// Two pages outlast a 15 s wait on one screen, so the last page's button arrives late by itself.
const pageMs = 8000;
const slideMs = 400;

export function StoryIntroTestScreen({ onFinished }: { onFinished?: () => void }) {
  const { width } = useWindowDimensions();
  const insets = useSafeAreaInsets();
  const { pop } = useNavigation();
  const [page, setPage] = useState(0);
  const [paused, setPaused] = useState(false);
  const [finished, setFinished] = useState(false);
  const offset = useRef(new Animated.Value(0)).current;
  const progress = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    Animated.timing(offset, { toValue: -page * width, duration: slideMs, easing: Easing.out(Easing.cubic), useNativeDriver: false }).start();
  }, [offset, page, width]);

  const remaining = useRef(pageMs);
  useEffect(() => {
    remaining.current = pageMs;
    progress.setValue(0);
  }, [page, progress]);

  useEffect(() => {
    if (finished || paused) {
      return undefined;
    }
    const started = Date.now();
    const run = Animated.timing(progress, { toValue: 1, duration: remaining.current, easing: Easing.linear, useNativeDriver: true });
    run.start(({ finished: ended }) => {
      if (ended && page < last) {
        fixtureLog('story-intro-test', `timer to page ${page + 2}`);
        setPage(page + 1);
      }
    });
    return () => {
      run.stop();
      remaining.current = Math.max(0, remaining.current - (Date.now() - started));
    };
  }, [finished, page, paused, progress]);

  const press = (event: GestureResponderEvent) => {
    const x = event.nativeEvent.pageX;
    const next = x < width / 3 ? Math.max(page - 1, 0) : Math.min(page + 1, last);
    fixtureLog('story-intro-test', `tap in ${x < width / 3 ? 'left third' : 'right two thirds'}, page ${next + 1}`);
    setPage(next);
  };

  const finish = () => {
    fixtureLog('story-intro-test', 'finished');
    setFinished(true);
    onFinished?.();
  };

  const state = finished ? 'Finished' : `${paused ? 'Paused on' : 'Page'} ${page + 1}`;

  return (
    <View style={[styles.root, { paddingTop: insets.top, paddingBottom: insets.bottom }]}>
      <View testID="story-intro" style={styles.story}>
        <Animated.View style={[styles.row, { width: width * pages.length, transform: [{ translateX: offset }] }]}>
          {pages.map((item, index) => (
            <Pressable
              key={item.title}
              onPress={press}
              onLongPress={() => {
                fixtureLog('story-intro-test', `paused on page ${page + 1}`);
                setPaused(true);
              }}
              onPressOut={() => setPaused(false)}
              style={[styles.page, { width }]}
            >
              <Text style={styles.title}>{item.title}</Text>
              <Text style={styles.body}>{item.body}</Text>
              {index === last && <Target id="story-intro-start" label="Get Started" onPress={finish} style={styles.start} />}
            </Pressable>
          ))}
        </Animated.View>
        <View accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={styles.bars}>
          {pages.map((item, index) => (
            <View key={item.title} style={styles.bar}>
              <Animated.View
                style={[
                  styles.barFill,
                  { transform: [{ scaleX: index < page ? 1 : index === page ? progress : 0 }] },
                ]}
              />
            </View>
          ))}
        </View>
      </View>
      <View style={styles.footer}>
        <Readout id="story-intro-state" label={`Story: ${state}`} value={state} />
        {!onFinished && <Target id="story-intro-leave" label="Leave Story" onPress={pop} style={styles.leave} textStyle={styles.leaveText} />}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colours.background },
  story: { flex: 1, overflow: 'hidden' },
  row: { flex: 1, flexDirection: 'row' },
  page: { justifyContent: 'center', gap: 16, padding: 32 },
  title: { fontSize: 34, fontWeight: '700', color: colours.text },
  body: { fontSize: 17, color: colours.secondary },
  bars: { position: 'absolute', top: 12, left: 16, right: 16, flexDirection: 'row', gap: 6 },
  bar: { flex: 1, height: 3, borderRadius: 2, overflow: 'hidden', backgroundColor: colours.separator },
  barFill: { ...StyleSheet.absoluteFill, backgroundColor: colours.accent, transformOrigin: 'left' },
  start: { marginTop: 32 },
  footer: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
    minHeight: 52,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colours.separator,
  },
  leave: { backgroundColor: 'transparent' },
  leaveText: { color: colours.accent },
});
