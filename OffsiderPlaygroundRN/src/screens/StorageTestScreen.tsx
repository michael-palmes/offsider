import AsyncStorage from '@react-native-async-storage/async-storage';
import { useCallback, useEffect, useState } from 'react';
import { StyleSheet } from 'react-native';

import { fixtureLog, Readout, Screen, Target } from '../fixtures';

const entries: [string, string][] = [
  ['offsider-fixture-theme', 'dark'],
  ['offsider-fixture-profile', JSON.stringify({ plan: 'basic', visits: 3 })],
];
const keys = entries.map(([key]) => key);

export function StorageTestScreen() {
  const [stored, setStored] = useState('Reading');

  const run = useCallback(async (what: string, change?: () => Promise<void>) => {
    try {
      await change?.();
      const found = (await AsyncStorage.getAllKeys()).filter((key) => keys.includes(key));
      fixtureLog('storage-test', `${what}, ${found.length} stored`);
      setStored(String(found.length));
    } catch (error) {
      fixtureLog('storage-test', `${what} failed: ${String(error)}`);
      setStored('Failed');
    }
  }, []);

  useEffect(() => {
    void run('keys read');
  }, [run]);

  return (
    <Screen route="storage-test" style={styles.content}>
      <Readout id="storage-test-count" label={`Stored Keys: ${stored}`} value={stored} />
      <Target id="storage-test-write" label="Write Keys" onPress={() => void run('keys written', () => AsyncStorage.multiSet(entries))} />
      <Target id="storage-test-clear" label="Clear Keys" onPress={() => void run('keys cleared', () => AsyncStorage.multiRemove(keys))} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { alignItems: 'center', gap: 16, padding: 16 },
});
