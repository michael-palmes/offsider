import { useEffect, useMemo, useState } from 'react';
import { BackHandler, Linking, Platform, Settings, StatusBar } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { introFromUrl, isRouteId, type Navigation, NavigationContext, type RouteId, routeFromUrl } from './src/navigation';
import { MenuScreen } from './src/screens/MenuScreen';
import { screens } from './src/screens';
import { StoryIntroTestScreen } from './src/screens/StoryIntroTestScreen';

function launchArgumentRoute(): RouteId | null {
  if (Platform.OS !== 'ios') {
    return null;
  }
  const value: unknown = Settings.get('OffsiderScreen');
  return isRouteId(value) ? value : null;
}

function launchArgumentIntro(): boolean {
  return Platform.OS === 'ios' && String(Settings.get('OffsiderIntro')) === '1';
}

export default function App() {
  const [intro, setIntro] = useState(launchArgumentIntro);
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
        setIntro(introFromUrl(url));
      }
    });
    const subscription = Linking.addEventListener('url', ({ url }) => {
      const route = routeFromUrl(url);
      if (route) {
        setStack([route]);
        setIntro(introFromUrl(url));
      }
    });
    return () => {
      cancelled = true;
      subscription.remove();
    };
  }, []);

  const depth = stack.length;
  useEffect(() => {
    if (depth === 0 || intro) {
      return;
    }
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
      setStack((current) => current.slice(0, -1));
      return true;
    });
    return () => subscription.remove();
  }, [depth, intro]);

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
        {intro ? <StoryIntroTestScreen onFinished={() => setIntro(false)} /> : <Current key={`${depth}-${top ?? 'menu'}`} />}
      </NavigationContext.Provider>
    </SafeAreaProvider>
  );
}
