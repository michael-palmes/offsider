import { useEffect, useRef, useState } from 'react';
import { StyleSheet, TextInput } from 'react-native';

import { colours, Note, Readout, Screen, Target } from '../fixtures';

type Session = 'Signed out' | 'Signing in' | 'Signed in' | 'Refused';

const signInDelayMs = 800;

const fieldProps = {
  autoCorrect: false,
  autoCapitalize: 'none',
  spellCheck: false,
  autoComplete: 'off',
  textContentType: 'none',
  importantForAutofill: 'no',
  smartInsertDelete: false,
} as const;

export function UserSwitchTestScreen() {
  const [session, setSession] = useState<Session>('Signed out');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [current, setCurrent] = useState('');
  const [signIns, setSignIns] = useState(0);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timer.current) {
        clearTimeout(timer.current);
      }
    },
    [],
  );

  const submit = () => {
    const name = email.trim();
    if (name.length === 0 || password.length === 0) {
      return;
    }
    setEmail('');
    setPassword('');
    setSession('Signing in');
    timer.current = setTimeout(() => {
      timer.current = null;
      if (name.toLowerCase().startsWith('refused')) {
        setSession('Refused');
        return;
      }
      setCurrent(name);
      setSignIns((count) => count + 1);
      setSession('Signed in');
    }, signInDelayMs);
  };

  const signOut = () => {
    setCurrent('');
    setSession('Signed out');
  };

  const showForm = session === 'Signed out' || session === 'Refused';

  return (
    <Screen route="user-switch-test" style={styles.content}>
      <Readout id="user-switch-test-state" label={`Session: ${session}`} value={session} />
      <Readout id="user-switch-test-sign-ins" label={`Sign-ins: ${signIns}`} value={String(signIns)} />

      {session === 'Refused' && <Readout id="user-switch-test-error" label="This account cannot sign in" />}

      {showForm && (
        <>
          <Note>Email</Note>
          <TextInput
            testID="user-switch-test-email"
            accessibilityLabel="Email"
            keyboardType="email-address"
            onChangeText={setEmail}
            style={styles.field}
            {...fieldProps}
          />
          <Note>Password</Note>
          <TextInput
            testID="user-switch-test-password"
            accessibilityLabel="Password"
            secureTextEntry
            onChangeText={setPassword}
            style={styles.field}
            {...fieldProps}
          />
          <Target id="user-switch-test-submit" label="Sign in" onPress={submit} />
        </>
      )}

      {session === 'Signed in' && (
        <>
          <Readout id="user-switch-test-current" label={`Signed in as ${current}`} />
          <Target
            id="user-switch-test-sign-out"
            label="Sign out"
            onPress={signOut}
            style={styles.secondary}
            textStyle={styles.secondaryText}
          />
        </>
      )}
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
  secondary: { backgroundColor: colours.panel },
  secondaryText: { color: colours.accent },
});
