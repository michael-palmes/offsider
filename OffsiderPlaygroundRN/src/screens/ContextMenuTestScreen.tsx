import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { colours, Readout, Screen, Target } from '../fixtures';

export function ContextMenuTestScreen() {
  const [state, setState] = useState('Initial');
  const [menuOpen, setMenuOpen] = useState(false);

  const choose = (next: string) => {
    setState(next);
    setMenuOpen(false);
  };

  return (
    <Screen route="context-menu-test" style={styles.content}>
      <Readout id="context-menu-test-state" label={`Context Menu State: ${state}`} value={state} />
      <Target
        id="context-menu-test-target"
        label="Long Press Target"
        onPress={() => {
          setMenuOpen(false);
          setState('Tapped');
        }}
        onLongPress={() => setMenuOpen(true)}
      />
      {menuOpen && (
        <View style={styles.menu}>
          <Target
            id="context-menu-test-favorite"
            label="Favorite"
            onPress={() => choose('Favorited')}
            style={styles.item}
            textStyle={styles.itemText}
          />
          <Target
            id="context-menu-test-archive"
            label="Archive"
            onPress={() => choose('Archived')}
            style={styles.item}
            textStyle={styles.itemText}
          />
        </View>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 24, alignItems: 'center' },
  menu: {
    width: 240,
    borderRadius: 12,
    overflow: 'hidden',
    backgroundColor: colours.panel,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colours.separator,
  },
  item: { alignItems: 'flex-start', borderRadius: 0, backgroundColor: 'transparent' },
  itemText: { fontWeight: '400', color: colours.text },
});
