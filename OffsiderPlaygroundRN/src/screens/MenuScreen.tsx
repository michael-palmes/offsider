import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, HeaderMarker, Note, Target } from '../fixtures';
import { routeIds, routeInfo, useNavigation } from '../navigation';

const sections = routeIds.reduce<{ title: string; routes: typeof routeIds }[]>((result, route) => {
  const title = routeInfo[route].section;
  const section = result.find((candidate) => candidate.title === title);
  if (section) {
    section.routes.push(route);
  } else {
    result.push({ title, routes: [route] });
  }
  return result;
}, []);

export function MenuScreen() {
  const insets = useSafeAreaInsets();
  const { push } = useNavigation();
  return (
    <ScrollView
      style={styles.scroll}
      contentContainerStyle={{ paddingTop: insets.top + 8, paddingBottom: insets.bottom + 24 }}
    >
      <HeaderMarker id="menu-title" title="Offsider Playground" textStyle={styles.title} />
      {sections.map((section) => (
        <View key={section.title} style={styles.section}>
          <HeaderMarker
            id={`menu-section-${section.title.toLowerCase().replace(/[^a-z]+/g, '-')}`}
            title={section.title}
            textStyle={styles.sectionTitle}
          />
          <View style={styles.group}>
            {section.routes.map((route) => (
              <Target
                key={route}
                id={`menu-${route}`}
                label={routeInfo[route].menuTitle}
                hint={routeInfo[route].subtitle}
                onPress={() => push(route)}
                style={styles.row}
              >
                <Text importantForAccessibility="no" style={styles.rowTitle}>
                  {routeInfo[route].menuTitle}
                </Text>
                <Note style={styles.rowSubtitle}>{routeInfo[route].subtitle}</Note>
              </Target>
            ))}
          </View>
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: colours.panel },
  title: { fontSize: 34, fontWeight: '700', textAlign: 'left', marginHorizontal: 16, marginBottom: 8 },
  section: { marginTop: 16 },
  sectionTitle: {
    fontSize: 13,
    fontWeight: '400',
    textAlign: 'left',
    color: colours.secondary,
    marginHorizontal: 32,
    marginBottom: 6,
  },
  group: { marginHorizontal: 16, borderRadius: 10, overflow: 'hidden', backgroundColor: colours.background },
  row: {
    alignItems: 'flex-start',
    backgroundColor: colours.background,
    borderRadius: 0,
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
  rowTitle: { fontSize: 17, fontWeight: '600', color: colours.text },
  rowSubtitle: { fontSize: 12, marginTop: 2 },
});
