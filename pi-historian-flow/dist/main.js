// src/main.ts
var decoder = new TextDecoder();
function onMessage(message, _context) {
  const line = typeof message.payload === "string" ? message.payload : decoder.decode(message.payload);
  const tab = line.indexOf("	");
  if (tab < 0) return [];
  return [{
    time: message.time,
    topic: line.slice(0, tab),
    payload: line.slice(tab + 1)
  }];
}
function onStartup() {
  return [];
}
function onInterval() {
  return [];
}
export {
  onInterval,
  onMessage,
  onStartup
};
