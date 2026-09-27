import { useState } from 'react';
import { Modal, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { colours, HeaderMarker, Readout, Screen, Target } from '../fixtures';

type ModalRoute = 'root' | 'detail';

export function ModalNavigationTestScreen() {
  const [state, setState] = useState('Initial');
  const [modalStack, setModalStack] = useState<ModalRoute[]>([]);
  const top = modalStack[modalStack.length - 1];

  const close = () => setModalStack([]);
  const back = () => setModalStack((current) => current.slice(0, -1));

  return (
    <Screen route="modal-navigation-test" style={styles.content}>
      <Readout id="modal-navigation-test-state" label={`Modal Navigation State: ${state}`} value={state} />
      <Target id="modal-navigation-test-open" label="Open Modal Flow" onPress={() => setModalStack(['root'])} />
      <Modal visible={top !== undefined} animationType="slide" presentationStyle="pageSheet" onRequestClose={back}>
        <SafeAreaView style={styles.modal}>
          {top === 'detail' ? (
            <>
              <View style={styles.bar}>
                <Target
                  id="modal-navigation-test-back"
                  label="Modal Flow"
                  onPress={back}
                  style={styles.barButton}
                  textStyle={styles.barButtonText}
                />
              </View>
              <View style={styles.body}>
                <Readout id="modal-navigation-test-detail" label="Modal Detail" role="header" textStyle={styles.title} />
                <Target id="modal-navigation-test-complete" label="Mark Complete" onPress={() => setState('Completed')} />
              </View>
            </>
          ) : (
            <>
              <View style={styles.bar}>
                <HeaderMarker id="modal-navigation-test-modal" title="Modal Flow" style={styles.barTitle} />
                <Target
                  id="modal-navigation-test-done"
                  label="Done"
                  onPress={close}
                  style={styles.barButton}
                  textStyle={styles.barButtonText}
                />
              </View>
              <Target
                id="modal-navigation-test-detail-link"
                label="Open Detail"
                onPress={() => setModalStack((current) => [...current, 'detail'])}
                style={styles.row}
                textStyle={styles.rowText}
              />
            </>
          )}
        </SafeAreaView>
      </Modal>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 24, alignItems: 'center' },
  modal: { flex: 1, backgroundColor: colours.panel },
  bar: { flexDirection: 'row', alignItems: 'center', minHeight: 56, paddingHorizontal: 8 },
  barTitle: { flex: 1, marginLeft: 52 },
  barButton: { backgroundColor: 'transparent', paddingHorizontal: 8 },
  barButtonText: { color: colours.accent, fontWeight: '600' },
  body: { alignItems: 'center', gap: 24, padding: 16 },
  title: { fontSize: 20, fontWeight: '700' },
  row: { marginHorizontal: 16, alignItems: 'flex-start', backgroundColor: colours.background },
  rowText: { color: colours.text, fontWeight: '400' },
});
