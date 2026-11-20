import { useState } from 'react';
import { StyleSheet, Switch, TextInput, View } from 'react-native';

import { colours, Note, Readout, Screen, Target } from '../fixtures';

type Step = 'email' | 'password' | 'created';

const fieldProps = {
  autoCorrect: false,
  autoCapitalize: 'none',
  spellCheck: false,
  smartInsertDelete: false,
} as const;

/** Email, then password and confirm with a show-password switch. The readout says whether the two match, never what they hold. */
export function SignUpScreen() {
  const [step, setStep] = useState<Step>('email');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [showPassword, setShowPassword] = useState(false);

  const match =
    password === '' && confirm === ''
      ? 'Both empty'
      : confirm === ''
        ? 'Confirm empty'
        : password === confirm
          ? 'Passwords match'
          : 'Passwords differ';

  return (
    <Screen route="sign-up" style={styles.content}>
      {step === 'email' && (
        <>
          <Note>Email</Note>
          <TextInput
            testID="signup-email"
            accessibilityLabel="Email"
            keyboardType="email-address"
            autoComplete="username"
            value={email}
            onChangeText={setEmail}
            style={styles.field}
            {...fieldProps}
          />
          <Target id="signup-next" label="Next" onPress={() => setStep('password')} />
        </>
      )}

      {step === 'password' && (
        <>
          <Readout id="signup-email-state" label={email === '' ? 'No email' : 'Email entered'} />
          <Note>Password</Note>
          <TextInput
            testID="signup-password"
            accessibilityLabel="Password"
            secureTextEntry={!showPassword}
            autoComplete="new-password"
            value={password}
            onChangeText={setPassword}
            style={styles.field}
            {...fieldProps}
          />
          <Note>Confirm password</Note>
          <TextInput
            testID="signup-confirm"
            accessibilityLabel="Confirm password"
            secureTextEntry={!showPassword}
            autoComplete="new-password"
            value={confirm}
            onChangeText={setConfirm}
            style={styles.field}
            {...fieldProps}
          />
          <View style={styles.row}>
            <Note style={styles.rowLabel}>Show password</Note>
            <Switch
              testID="signup-show-password"
              accessibilityLabel="Show password"
              value={showPassword}
              onValueChange={setShowPassword}
            />
          </View>
          <Readout id="signup-match" label={match} />
          <Target id="signup-create" label="Create account" onPress={() => setStep('created')} />
        </>
      )}

      {step === 'created' && <Readout id="signup-result" label="Account created" />}
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 12, alignItems: 'stretch' },
  field: {
    height: 44,
    paddingHorizontal: 12,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: colours.separator,
    fontSize: 17,
    color: colours.text,
  },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  rowLabel: { flex: 1 },
});
