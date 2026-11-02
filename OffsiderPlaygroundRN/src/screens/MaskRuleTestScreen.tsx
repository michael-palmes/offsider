import { useState } from 'react';
import { StyleSheet, Text, TextInput, View } from 'react-native';

import { colours, Screen, Target } from '../fixtures';

export function MaskRuleTestScreen() {
  const [revealed, setRevealed] = useState(false);

  return (
    <Screen route="mask-rule-test" style={styles.content}>
      <TextInput
        testID="mask-rule-test-password"
        accessibilityLabel="Fixture Password"
        defaultValue="4821-fixture"
        secureTextEntry={!revealed}
        autoCapitalize="none"
        autoCorrect={false}
        style={styles.field}
      />
      <Target
        id="mask-rule-test-reveal"
        label={revealed ? 'Hide Password' : 'Show Password'}
        onPress={() => setRevealed((current) => !current)}
      />
      <Target id="mask-rule-test-balance-row" label="Balance 7730.25 Details" onPress={() => {}} style={styles.row}>
        <Text style={styles.rowText}>Balance</Text>
        <Text testID="mask-rule-test-balance-amount" style={styles.rowText}>
          7730.25
        </Text>
        <Text style={styles.rowText}>Details</Text>
      </Target>
      <View testID="mask-rule-test-card" collapsable={false} style={styles.card}>
        <Text testID="mask-rule-test-card-holder" style={styles.rowText}>
          Holder 5519
        </Text>
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 16 },
  field: { minHeight: 44, paddingHorizontal: 12, borderRadius: 8, backgroundColor: colours.panel, color: colours.text },
  row: { flexDirection: 'row', gap: 12, backgroundColor: colours.panel },
  rowText: { fontSize: 15, color: colours.text },
  card: { padding: 16, borderRadius: 8, backgroundColor: colours.panel },
});
