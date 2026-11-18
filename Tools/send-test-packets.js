#!/usr/bin/env node
/*
 * send-test-packets.js — fire Art-Net at the monitor without any hardware.
 *
 *   node send-test-packets.js                 # 127.0.0.1, 5 seconds
 *   node send-test-packets.js 10.0.0.23 20    # another machine, 20 seconds
 *
 * Sends ArtDmx on universes 0, 1 and 21 (21 is 0.1.5 in Resolume's three
 * input fields) at 20 fps, plus an ArtPoll every second. Listen mode picks
 * these up. Capture mode will not see loopback traffic — pktap does not carry
 * it — so point this at the Mac's LAN address if you want to test Capture.
 */
'use strict';
const dgram = require('dgram');

const host = process.argv[2] || '127.0.0.1';
const seconds = Number(process.argv[3] || 5);
const PORT = 6454;
const UNIVERSES = [0, 1, 21];
const HEADER = Buffer.from('Art-Net\0', 'ascii');

const sock = dgram.createSocket('udp4');
sock.bind(() => { try { sock.setBroadcast(true); } catch (_) {} });

let seq = 0;
let phase = 0;

function artDmx(universe, sequence, offset) {
  const head = Buffer.alloc(18);
  HEADER.copy(head, 0);
  head.writeUInt16LE(0x5000, 8);      // OpDmx
  head.writeUInt16BE(14, 10);         // protocol version
  head[12] = sequence;
  head[13] = 0;                       // physical
  head[14] = universe & 0xff;         // SubUni
  head[15] = (universe >> 8) & 0x7f;  // Net
  head.writeUInt16BE(512, 16);        // length, big-endian

  const data = Buffer.alloc(512);
  for (let ch = 0; ch < 24; ch++) {
    data[ch] = Math.round(((Math.sin(offset + ch * 0.4) + 1) / 2) * 255);
  }
  data[9] = (sequence * 3) & 0xff;    // channel 10 always moves
  return Buffer.concat([head, data]);
}

function artPoll() {
  const b = Buffer.alloc(14);
  HEADER.copy(b, 0);
  b.writeUInt16LE(0x2000, 8);
  b.writeUInt16BE(14, 10);
  b[12] = 0x02;
  return b;
}

const frames = setInterval(() => {
  seq = seq >= 255 ? 1 : seq + 1;
  phase += 0.12;
  for (const u of UNIVERSES) sock.send(artDmx(u, seq, phase + u), PORT, host);
}, 50);

const polls = setInterval(() => sock.send(artPoll(), PORT, host), 1000);

console.log(`sending Art-Net to ${host}:${PORT} — universes ${UNIVERSES.join(', ')} at 20 fps`);
setTimeout(() => {
  clearInterval(frames);
  clearInterval(polls);
  sock.close();
  console.log('done');
}, seconds * 1000);
