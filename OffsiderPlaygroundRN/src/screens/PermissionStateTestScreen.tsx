import { useCallback, useEffect, useState } from 'react';
import { AppState, PermissionsAndroid, Platform, StyleSheet } from 'react-native';

import { Readout, Screen, Target } from '../fixtures';

type PermissionState = 'granted' | 'denied' | 'not available' | 'checking';

const permissions = {
  camera: PermissionsAndroid.PERMISSIONS.CAMERA,
  notifications: PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS,
} as const;

async function check(permission: (typeof permissions)[keyof typeof permissions]): Promise<PermissionState> {
  if (Platform.OS !== 'android') {
    return 'not available';
  }
  return (await PermissionsAndroid.check(permission)) ? 'granted' : 'denied';
}

export function PermissionStateTestScreen() {
  const [camera, setCamera] = useState<PermissionState>('checking');
  const [notifications, setNotifications] = useState<PermissionState>('checking');
  const [refreshes, setRefreshes] = useState(0);

  const refresh = useCallback(async () => {
    setCamera(await check(permissions.camera));
    setNotifications(await check(permissions.notifications));
    setRefreshes((count) => count + 1);
  }, []);

  useEffect(() => {
    void refresh();
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void refresh();
      }
    });
    return () => subscription.remove();
  }, [refresh]);

  return (
    <Screen route="permission-state" style={styles.content}>
      <Readout id="permission-state-camera" label={`Camera: ${camera}`} value={camera} />
      <Readout id="permission-state-notifications" label={`Notifications: ${notifications}`} value={notifications} />
      <Readout id="permission-state-refreshes" label={`Refreshes: ${refreshes}`} value={String(refreshes)} />
      <Target id="permission-state-refresh" label="Refresh" onPress={() => void refresh()} />
      <Target
        id="permission-state-request-camera"
        label="Request Camera"
        onPress={async () => {
          if (Platform.OS === 'android') {
            await PermissionsAndroid.request(permissions.camera);
          }
          await refresh();
        }}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 16 },
});
