import { useEffect, useMemo, useState } from 'react';
import { BackHandler, Linking, Platform, Settings, StatusBar } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { isRouteId, type Navigation, NavigationContext, type RouteId, routeFromUrl } from './src/navigation';
import { MenuScreen } from './src/screens/MenuScreen';
import { screens } from './src/screens';

function launchArgumentRoute(): RouteId | null {
  if (Platform.OS !== 'ios') {
    return null;
  }
  const value: unknown = Settings.get('OffsiderScreen');
  return isRouteId(value) ? value : null;
}

export default function App() {
  const [stack, setStack] = useState<RouteId[]>(() => {
    const route = launchArgumentRoute();
    return route ? [route] : [];
  });

  useEffect(() => {
    let cancelled = false;
    Linking.getInitialURL().then((url) => {
      const route = routeFromUrl(url);
      if (route && !cancelled) {
        setStack([route]);
      }
    });
    const subscription = Linking.addEventListener('url', ({ url }) => {
      const route = routeFromUrl(url);
      if (route) {
        setStack([route]);
      }
    });
    return () => {
      cancelled = true;
      subscription.remove();
    };
  }, []);

  const depth = stack.length;
  useEffect(() => {
    if (depth === 0) {
      return;
    }
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
      setStack((current) => current.slice(0, -1));
      return true;
    });
    return () => subscription.remove();
  }, [depth]);

  const navigation = useMemo<Navigation>(
    () => ({
      push: (route) => setStack((current) => [...current, route]),
      pop: () => setStack((current) => current.slice(0, -1)),
    }),
    [],
  );

  const top = stack[depth - 1];
  const Current = top ? screens[top] : MenuScreen;

  return (
    <SafeAreaProvider>
      <StatusBar barStyle="dark-content" />
      <NavigationContext.Provider value={navigation}>
        <Current key={`${depth}-${top ?? 'menu'}`} />
      </NavigationContext.Provider>
    </SafeAreaProvider>
  );
}
