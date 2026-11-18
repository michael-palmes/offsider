import { useMemo, useState } from 'react';
import { StyleSheet, TextInput } from 'react-native';
import { WebView, type WebViewMessageEvent } from 'react-native-webview';

import { colours, fixtureLog, isLocalPage, Readout, Screen, Target } from '../fixtures';

const modes = ['Pass', 'Expire', 'Error'] as const;
type Mode = (typeof modes)[number];
type Check = 'Waiting' | 'Passed' | 'Expired' | 'Failed';

const verifyMs = 600;
const expireMs = 4000;

const widget = (mode: Mode) => `<!doctype html>
<html>
<head>
<style>
html, body { margin: 0; height: 100%; font: 14px -apple-system, Roboto, sans-serif; color: #1C1C1E; }
.box { box-sizing: border-box; height: 100%; display: flex; align-items: center; justify-content: space-between;
  padding: 0 12px; border: 1px solid #D1D1D6; background: #FAFAFA; }
label:not([hidden]) { display: flex; align-items: center; gap: 12px; }
input { width: 24px; height: 24px; margin: 0; }
a { font-size: 11px; color: #6C6C70; }
</style>
</head>
<body>
<div class="box">
<label id="prompt"><input id="tick" type="checkbox"><span>Verify you are human</span></label>
<span id="status" role="status" hidden></span>
<a id="logo" href="#">Cloudflare</a>
</div>
<script>
var mode = '${mode}';
var timer = null;
var tick = document.getElementById('tick');
var promptRow = document.getElementById('prompt');
var statusText = document.getElementById('status');

function show(text) {
  promptRow.hidden = text !== null;
  statusText.hidden = text === null;
  statusText.textContent = text || '';
}

function reset() {
  clearTimeout(timer);
  tick.checked = false;
  show(null);
}

function tell(type) {
  parent.postMessage(JSON.stringify({ type: type }), '*');
}

tick.addEventListener('change', function () {
  if (!tick.checked) { return; }
  show('Verifying...');
  timer = setTimeout(function () {
    if (mode === 'Error') {
      show('Verification failed');
      tell('error');
      return;
    }
    show('Success!');
    tell('token');
    if (mode === 'Expire') {
      timer = setTimeout(function () {
        reset();
        tell('expired');
      }, ${expireMs});
    }
  }, ${verifyMs});
});

document.getElementById('logo').addEventListener('click', function (event) { event.preventDefault(); });
</script>
</body>
</html>`;

// The widget sits in a frame of its own inside the page, as a hosted one does.
const html = (mode: Mode) => `<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
html, body { margin: 0; height: 100%; overflow: hidden; background: transparent; }
iframe { display: block; width: 300px; height: 65px; border: 0; }
</style>
</head>
<body>
<div id="cf-chl-widget-fixture"><iframe id="frame" title="Widget containing a Cloudflare security challenge"></iframe></div>
<script>
var frame = document.getElementById('frame');
frame.srcdoc = ${JSON.stringify(widget(mode)).replace(/</g, '\\u003c')};

window.addEventListener('message', function (event) {
  if (event.source === frame.contentWindow) {
    window.ReactNativeWebView.postMessage(event.data);
  }
});
</script>
</body>
</html>`;

const checks: Record<string, Check> = { token: 'Passed', expired: 'Expired', error: 'Failed' };

export function CheckWidgetTestScreen() {
  const [mode, setMode] = useState<Mode>('Pass');
  const [attempt, setAttempt] = useState(0);
  const source = useMemo(() => ({ html: html(mode) }), [mode]);
  const [check, setCheck] = useState<Check>('Waiting');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [result, setResult] = useState('None');

  const onMessage = (event: WebViewMessageEvent) => {
    const { type } = JSON.parse(event.nativeEvent.data) as { type: string };
    const next = checks[type];
    if (next) {
      fixtureLog('check-widget-test', `check ${next}`);
      setCheck(next);
    }
  };

  const nextMode = () => {
    const next = modes[(modes.indexOf(mode) + 1) % modes.length];
    fixtureLog('check-widget-test', `mode ${next}`);
    setMode(next);
    setCheck('Waiting');
    setResult('None');
  };

  const submit = () => {
    const next = check !== 'Passed' ? 'Refused, check not passed' : email && password ? 'Accepted' : 'Refused, fields empty';
    fixtureLog('check-widget-test', `sign in ${next}`);
    setResult(next);
    if (next !== 'Accepted') {
      // A refused sign-in loads the widget again, so an earlier tick is gone.
      setCheck('Waiting');
      setAttempt((current) => current + 1);
    }
  };

  return (
    <Screen route="check-widget-test" style={styles.content}>
      <Readout id="check-widget-state" label={`Check: ${check}`} value={check} />
      <Readout id="check-widget-result" label={`Sign In: ${result}`} value={result} />
      <Target id="check-widget-mode" label={`Check Mode: ${mode}`} onPress={nextMode} style={styles.mode} textStyle={styles.modeText} />
      <TextInput
        testID="check-widget-email"
        accessibilityLabel="Email"
        placeholder="Email"
        placeholderTextColor={colours.secondary}
        value={email}
        onChangeText={setEmail}
        autoCapitalize="none"
        autoCorrect={false}
        keyboardType="email-address"
        style={styles.field}
      />
      <TextInput
        testID="check-widget-password"
        accessibilityLabel="Password"
        placeholder="Password"
        placeholderTextColor={colours.secondary}
        value={password}
        onChangeText={setPassword}
        secureTextEntry
        style={styles.field}
      />
      <WebView
        key={`${mode}-${attempt}`}
        testID="check-widget-turnstile"
        source={source}
        originWhitelist={['*']}
        onShouldStartLoadWithRequest={isLocalPage}
        onMessage={onMessage}
        javaScriptEnabled
        domStorageEnabled
        scrollEnabled={false}
        bounces={false}
        overScrollMode="never"
        style={styles.widget}
      />
      <Target id="check-widget-submit" label="Sign In" onPress={submit} style={styles.submit} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { gap: 12, padding: 16 },
  mode: { alignSelf: 'flex-start', backgroundColor: colours.panel },
  modeText: { color: colours.accent, fontSize: 15 },
  field: { height: 44, paddingHorizontal: 12, borderRadius: 8, backgroundColor: colours.panel, fontSize: 17, color: colours.text },
  widget: { flex: 0, width: '100%', height: 80, backgroundColor: 'transparent' },
  submit: { alignSelf: 'stretch' },
});
