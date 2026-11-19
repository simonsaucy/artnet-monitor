// Deliberately harmless broadcast probe:
//   * universe 999 — far outside the 0-19 the Pixel Stix use
//   * every one of the 512 channels held at 0, so nothing can light up
//   * plus ArtPoll, which is a discovery packet and carries no levels
'use strict';
const dgram = require('dgram');
const host = process.argv[2];
const seconds = Number(process.argv[3] || 3);
const PORT = 6454, UNIVERSE = 999;
const HEADER = Buffer.from('Art-Net\0', 'ascii');

const sock = dgram.createSocket('udp4');
sock.bind(() => sock.setBroadcast(true));

let seq = 0;
function artDmxAllZero() {
  const h = Buffer.alloc(18);
  HEADER.copy(h, 0);
  h.writeUInt16LE(0x5000, 8);
  h.writeUInt16BE(14, 10);
  h[12] = seq = seq >= 255 ? 1 : seq + 1;
  h[14] = UNIVERSE & 0xff;
  h[15] = (UNIVERSE >> 8) & 0x7f;
  h.writeUInt16BE(512, 16);
  return Buffer.concat([h, Buffer.alloc(512)]);  // all zeros
}
function artPoll() {
  const b = Buffer.alloc(14);
  HEADER.copy(b, 0);
  b.writeUInt16LE(0x2000, 8);
  b.writeUInt16BE(14, 10);
  b[12] = 0x00;   // TalkToMe = 0: do not ask nodes to reply
  return b;
}

console.log(`broadcasting to ${host}:${PORT} — universe ${UNIVERSE}, all channels 0, for ${seconds}s`);
const t1 = setInterval(() => sock.send(artDmxAllZero(), PORT, host), 100);
const t2 = setInterval(() => sock.send(artPoll(), PORT, host), 1000);
setTimeout(() => { clearInterval(t1); clearInterval(t2); sock.close(); console.log('done'); }, seconds * 1000);
