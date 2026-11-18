import { useEffect, useRef, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { WebView, type WebViewMessageEvent } from 'react-native-webview';

import { colours, fixtureLog, isLocalPage, Readout, Screen, Target } from '../fixtures';

const tickMs = 120;

const html = `<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
html, body { margin: 0; height: 100%; overflow: hidden; background: #FFFFFF; touch-action: none; }
canvas { display: block; width: 100%; height: 100%; }
</style>
</head>
<body>
<canvas id="chart"></canvas>
<script>
var canvas = document.getElementById('chart');
var context = canvas.getContext('2d');
var values = [];
var last = 0;
var zoom = 1;
var pinch = 0;
var cross = null;

function valueAt(n) {
  return Math.round((100 + 20 * Math.sin(n / 6) + (n * 7) % 11) * 100) / 100;
}

function shown() {
  return Math.max(8, Math.round(60 / zoom));
}

function draw() {
  var ratio = window.devicePixelRatio || 1;
  var width = canvas.clientWidth;
  var height = canvas.clientHeight;
  var pixelWidth = Math.round(width * ratio);
  var pixelHeight = Math.round(height * ratio);
  if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
    canvas.width = pixelWidth;
    canvas.height = pixelHeight;
  }
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  context.fillStyle = '#FFFFFF';
  context.fillRect(0, 0, width, height);
  var count = shown();
  var slice = values.slice(-count);
  var low = Math.min.apply(null, slice);
  var span = Math.max.apply(null, slice) - low || 1;
  context.beginPath();
  slice.forEach(function (value, index) {
    var x = (index / (count - 1)) * width;
    var y = height - 16 - ((value - low) / span) * (height - 32);
    if (index) { context.lineTo(x, y); } else { context.moveTo(x, y); }
  });
  context.strokeStyle = '#007AFF';
  context.lineWidth = 2;
  context.stroke();
  if (cross !== null) {
    context.fillStyle = '#1C1C1E';
    context.fillRect(cross, 0, 1, height);
  }
}

function post(message) {
  window.ReactNativeWebView.postMessage(JSON.stringify(message));
}

function receive(event) {
  var message;
  try { message = JSON.parse(event.data); } catch (error) { return; }
  if (message.type !== 'tick' || message.n <= last) { return; }
  last = message.n;
  values.push(valueAt(60 + last));
  values.shift();
  draw();
}

function spread(touches) {
  var x = touches[0].clientX - touches[1].clientX;
  var y = touches[0].clientY - touches[1].clientY;
  return Math.sqrt(x * x + y * y);
}

function readout(touch) {
  var count = shown();
  var slice = values.slice(-count);
  cross = Math.round(touch.clientX);
  var index = Math.min(count - 1, Math.max(0, Math.round((cross / canvas.clientWidth) * (count - 1))));
  post({ type: 'readout', x: cross, value: slice[index] });
  draw();
}

function touched(event) {
  event.preventDefault();
  if (event.touches.length === 2) {
    if (!pinch) { pinch = spread(event.touches) / zoom; }
    zoom = Math.min(8, Math.max(1, spread(event.touches) / pinch));
    post({ type: 'zoom', zoom: Math.round(zoom * 10) / 10 });
    draw();
  } else if (event.touches.length === 1 && !pinch) {
    readout(event.touches[0]);
  }
}

for (var n = 0; n < 60; n += 1) { values.push(valueAt(n)); }
canvas.addEventListener('touchstart', touched, { passive: false });
canvas.addEventListener('touchmove', touched, { passive: false });
canvas.addEventListener('touchend', function (event) { if (event.touches.length === 0) { pinch = 0; } });
window.addEventListener('message', receive);
document.addEventListener('message', receive);
window.addEventListener('resize', draw);
draw();
</script>
</body>
</html>`;

type ChartMessage = { type: 'readout'; x: number; value: number } | { type: 'zoom'; zoom: number };

export function WebChartTestScreen() {
  const web = useRef<WebView>(null);
  const tick = useRef(0);
  const [loaded, setLoaded] = useState(false);
  const [running, setRunning] = useState(true);
  const [readout, setReadout] = useState('None');
  const [zoom, setZoom] = useState('1.0');

  useEffect(() => {
    if (!running || !loaded) {
      return undefined;
    }
    const timer = setInterval(() => {
      tick.current += 1;
      web.current?.postMessage(JSON.stringify({ type: 'tick', n: tick.current }));
    }, tickMs);
    return () => clearInterval(timer);
  }, [running, loaded]);

  const onMessage = (event: WebViewMessageEvent) => {
    const message = JSON.parse(event.nativeEvent.data) as ChartMessage;
    if (message.type === 'readout') {
      setReadout(`${message.value.toFixed(2)} at ${message.x}`);
    } else {
      setZoom(message.zoom.toFixed(1));
    }
  };

  return (
    <Screen route="web-chart-test" style={styles.content}>
      <Readout id="web-chart-readout" label={`Chart Readout: ${readout}`} value={readout} />
      <Readout id="web-chart-zoom" label={`Chart Zoom: ${zoom}x`} value={zoom} />
      <View testID="web-chart" style={styles.chart}>
        <WebView
          ref={web}
          source={{ html }}
          originWhitelist={['*']}
          onShouldStartLoadWithRequest={isLocalPage}
          onLoadEnd={() => setLoaded(true)}
          onMessage={onMessage}
          scrollEnabled={false}
          bounces={false}
          overScrollMode="never"
          style={styles.web}
        />
      </View>
      <Readout id="web-chart-ticks" label={`Chart Ticks: ${running ? 'Running' : 'Stopped'}`} value={running ? 'Running' : 'Stopped'} />
      <Target
        id="web-chart-toggle"
        label={running ? 'Stop Ticks' : 'Start Ticks'}
        onPress={() => {
          fixtureLog('web-chart-test', running ? 'stop ticks' : 'start ticks');
          setRunning((current) => !current);
        }}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { alignItems: 'center', gap: 12, padding: 16 },
  chart: { alignSelf: 'stretch', height: 320, borderWidth: StyleSheet.hairlineWidth, borderColor: colours.separator },
  web: { flex: 1, backgroundColor: colours.background },
});
