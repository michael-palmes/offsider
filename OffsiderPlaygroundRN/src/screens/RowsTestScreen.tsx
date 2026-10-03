import { useEffect, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, fixtureLog, Readout, Screen, Target } from '../fixtures';

const tickMs = 1000;
const itemHeight = 56;
const items = Array.from({ length: 40 }, (_, index) => index + 1);

export function RowsTestScreen() {
  const insets = useSafeAreaInsets();
  const [selected, setSelected] = useState('None');
  const [download, setDownload] = useState(0);
  const [live, setLive] = useState(true);

  useEffect(() => {
    if (!live) {
      return;
    }
    const interval = setInterval(() => setDownload((current) => (current >= 100 ? 0 : current + 1)), tickMs);
    return () => clearInterval(interval);
  }, [live]);

  const select = (name: string) => {
    fixtureLog('rows-test', `selected ${name}`);
    setSelected(name);
  };

  const rows = [
    { title: 'Inbox', detail: '3 unread' },
    { title: 'Downloads', detail: `${download}% complete` },
    { title: 'Today’s Summary', detail: 'Updated just now' },
    { title: 'Don’t Disturb', detail: 'Off' },
  ];

  return (
    <Screen route="rows-test">
      <View style={styles.pinned}>
        <Readout id="rows-test-state" label={`Rows Selected: ${selected}`} value={selected} />
        <Readout id="rows-test-download" label={`Download: ${download}%`} value={String(download)} />
        <Target
          id="rows-test-toggle-live"
          label={live ? 'Pause Updates' : 'Resume Updates'}
          onPress={() => {
            fixtureLog('rows-test', live ? 'pause updates' : 'resume updates');
            setLive((current) => !current);
          }}
        />
      </View>
      <ScrollView testID="rows-test-scroll-view" contentContainerStyle={{ paddingBottom: insets.bottom + 16 }}>
        {rows.map((row) => (
          <Pressable
            key={row.title}
            accessibilityRole="button"
            onPress={() => select(row.title)}
            style={({ pressed }) => [styles.row, pressed && styles.pressed]}
          >
            <Text style={styles.rowTitle}>{row.title}</Text>
            <Text style={styles.rowDetail}>{row.detail}</Text>
          </Pressable>
        ))}
        {items.map((item) => (
          <Target
            key={item}
            id={`rows-test-item-${item}`}
            label={`Item ${item}`}
            onPress={() => select(`Item ${item}`)}
            style={styles.item}
            textStyle={styles.itemText}
          />
        ))}
        <View style={styles.footer}>
          <Target id="rows-test-footer" label={'I’ve Read the Terms'} onPress={() => select('Terms')} />
          <Readout id="rows-test-end" label="End of List" />
        </View>
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  pinned: {
    padding: 16,
    gap: 8,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
  row: {
    paddingHorizontal: 16,
    paddingVertical: 10,
    backgroundColor: colours.background,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
  pressed: { opacity: 0.6 },
  rowTitle: { fontSize: 17, color: colours.text },
  rowDetail: { fontSize: 13, color: colours.secondary, marginTop: 2 },
  item: {
    height: itemHeight,
    alignItems: 'flex-start',
    borderRadius: 0,
    backgroundColor: colours.background,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
  itemText: { color: colours.text, fontWeight: '400' },
  footer: { padding: 16, gap: 16, alignItems: 'center' },
});
