// Token Bonfire의 불·동전·숫자 그림을 스프라이트 시트로 굽는다.
// 실행: node tools/bake/bake.mjs → Resources/ 아래에 PNG·JSON 생성. 시트는 가로 한 줄이고 JSON은 {width,height,durations}다.
// tools/bake/pixelfx 에 pixelfx(github.com/tinkerer0/pixelfx, a841596)가 있어야 한다.
import { deflateSync, inflateSync } from "node:zlib";
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { createFrame, clearFrame, createFx, composite, painterFor, fit, hex, FONTS } from "./pixelfx/src/core/index.js";
import * as campfire from "./campfire_wide.js";
import { Layer, coin3d } from "./pixelfx/src/fx/pickups/_lib.js";

const OUT = new URL("../../Resources/", import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });

const W = 160, H = 180, OX = 80, OY = 148, GLOW = 0.6, FPS = 30, FRAMES = 90;
// 소모 속도 5단계의 불 높이·굵기. 그 사이와 위(동전이 들어갈 때 솟는 몫)를 촘촘히 굽는다.
const TIER_H = [7, 14, 22, 31, 42], TIER_G = [1, 1.1, 1.2, 1.35, 1.5];
const LEVEL_H = [7, 10.5, 14, 18, 22, 26.5, 31, 36.5, 42, 48, 55];
const girthAt = (h) => {
  if (h >= 42) return 1.5;
  for (let i = 0; i < 4; i++) if (h <= TIER_H[i + 1]) return TIER_G[i] + ((h - TIER_H[i]) / (TIER_H[i + 1] - TIER_H[i])) * (TIER_G[i + 1] - TIER_G[i]);
  return 1;
};

// ---- PNG (RGBA 8비트, 필터 0) ----
const CRC = new Uint32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc = (buf) => { let c = 0xffffffff; for (const b of buf) c = CRC[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (type, data) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]), c = Buffer.alloc(4); c.writeUInt32BE(crc(td));
  return Buffer.concat([len, td, c]);
};
export function encodePng(w, h, rgba) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) Buffer.from(rgba.buffer, rgba.byteOffset + y * w * 4, w * 4).copy(raw, y * (w * 4 + 1) + 1);
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0))]);
}
function decodePng(buf) {
  const w = buf.readUInt32BE(16), h = buf.readUInt32BE(20), parts = [];
  for (let p = 8; p < buf.length;) { const n = buf.readUInt32BE(p), t = buf.toString("latin1", p + 4, p + 8); if (t === "IDAT") parts.push(buf.subarray(p + 8, p + 8 + n)); p += 12 + n; }
  const raw = inflateSync(Buffer.concat(parts)), out = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) { if (raw[y * (w * 4 + 1)] !== 0) throw new Error("filter"); out.set(raw.subarray(y * (w * 4 + 1) + 1, (y + 1) * (w * 4 + 1)), y * w * 4); }
  return { w, h, data: out };
}
// 가로 한 줄 시트에 칸 하나를 써 넣는다
const blit = (sheet, sw, cell, cw, ch, i) => { for (let y = 0; y < ch; y++) sheet.set(cell.subarray(y * cw * 4, (y + 1) * cw * 4), (y * sw + i * cw) * 4); };
const durations = (n, fps) => Array.from({ length: n }, (_, i) => Math.round(((i + 1) * 1000) / fps) - Math.round((i * 1000) / fps));

// ---- 불: 단계마다 90장 ----
function renderFire(level, i) {
  const h = LEVEL_H[level], frame = createFrame(W, H), out = new Uint8ClampedArray(W * H * 4);
  const fx = createFx(campfire, { x: OX, y: OY, light: GLOW, height: h, girth: girthAt(h) });
  fx.update(i / FPS);
  fx.draw(frame);
  composite(frame, out, null, 1);
  return out;
}
const fireFiles = [];
for (let L = 0; L < LEVEL_H.length; L++) {
  const sheet = new Uint8Array(W * FRAMES * H * 4);
  for (let i = 0; i < FRAMES; i++) blit(sheet, W * FRAMES, renderFire(L, i), W, H, i);
  const name = `fire-${String(L).padStart(2, "0")}`, png = encodePng(W * FRAMES, H, sheet);
  writeFileSync(OUT + name + "-atlas.png", png);
  writeFileSync(OUT + name + ".json", JSON.stringify({ width: W, height: H, durations: durations(FRAMES, FPS) }));
  fireFiles.push({ name, height: LEVEL_H[L], girth: +girthAt(LEVEL_H[L]).toFixed(3), bytes: png.length });
}

// ---- 동전: 한 바퀴 24장, 16x16 ----
const CW = 16, CN = 24, COIN = fit(["#1e1206", "#4a2c08", "#86520c", "#c48412", "#f0b424", "#ffe066", "#fff6c4", "#ffffff"], 8);
{
  const sheet = new Uint8Array(CW * CN * CW * 4), layer = new Layer(32, 32);
  for (let i = 0; i < CN; i++) {
    const frame = createFrame(CW, CW), out = new Uint8ClampedArray(CW * CW * 4), p = painterFor(frame);
    p.place(8, 8); p.lightK = GLOW;
    coin3d(layer, p, 0, 0, 4, 2, (i / CN) * Math.PI * 2, COIN);
    composite(frame, out, null, 1);
    blit(sheet, CW * CN, out, CW, CW, i);
  }
  writeFileSync(OUT + "coin-atlas.png", encodePng(CW * CN, CW, sheet));
  writeFileSync(OUT + "coin.json", JSON.stringify({ width: CW, height: CW, durations: durations(CN, 24) }));
}

// ---- 숫자: pixelfx big 글꼴(5x7) + 1px 외곽선, 칸 7x9 ----
const CHARS = "0123456789.KMBT", GW = 7, GH = 9, glyphs = {};
for (const [file, ink, outline] of [["digits", "#f4efe6", "#0b0b0d"]]) {
  const sheet = new Uint8Array(GW * CHARS.length * GH * 4);
  [...CHARS].forEach((ch, i) => {
    const frame = createFrame(GW, GH), out = new Uint8ClampedArray(GW * GH * 4), p = painterFor(frame);
    p.place(0, 0);
    p.text(ch, 1, 1, hex(ink), { font: "big", outline: hex(outline) });
    composite(frame, out, null, 1);
    blit(sheet, GW * CHARS.length, out, GW, GH, i);
    glyphs[ch] = { index: i, advance: FONTS.big.glyphs[ch].w + FONTS.big.gap };
  });
  writeFileSync(OUT + file + "-atlas.png", encodePng(GW * CHARS.length, GH, sheet));
}

// ---- 설명서 ----
writeFileSync(OUT + "manifest.json", JSON.stringify({
  note: "Token Bonfire 그림 규격. 불은 pixelfx Campfire(MIT)로 그렸다. 좌표는 불 칸(160x180) 기준, origin이 장작 바닥 가운데.",
  frame: { width: W, height: H, originX: OX, originY: OY, fps: FPS, frames: FRAMES },
  fireLevels: fireFiles.map(({ name, height, girth }) => ({ atlas: name + "-atlas.png", height, girth })),
  tiers: ["대기", "약", "중", "강", "폭주"].map((name, i) => ({ name, level: LEVEL_H.indexOf(TIER_H[i]), coinsPerSecond: [0, 1, 3, 7, 16][i], coinSpreadX: [14, 16, 18, 22, 26][i] })),
  levelChange: "목표 단계로 초당 4배율 지수 접근. 모든 단계가 같은 장 번호에서 같은 흔들림이라 장 번호를 유지한 채 단계만 바꾸면 이어진다.",
  coin: { atlas: "coin-atlas.png", size: CW, frames: CN, spinRadPerSecond: [7, 12], startY: -OY - 14, startYJitter: 30, startSpeed: [30, 70], gravity: 320, landY: -9 },
  flare: { onCoinLand: "+0.5 (최대 1), 초당 e^-4 로 감쇠", levelBoostAtFull: 2 },
  number: { atlas: "digits-atlas.png", cell: [GW, GH], chars: CHARS, glyphs, topY: 9, align: "center", inkOffset: [1, 1], format: "1000 미만은 정수, 그 위는 소수 한 자리(내림)에 K(천)·M(백만)·B(십억)·T(조). 1000 단위를 채우면 다음 단위로 올린다. 동전이 들어갈 때만 갱신" },
  counter: { start: "앱을 켠 순간 0부터", resetButton: true, counts: "입력 + 캐시 쓰기 + 출력 (캐시 읽기 제외)" },
}, null, 1));

// ---- 검증: 구운 PNG를 다시 풀어 새로 그린 장과 바이트 비교 ----
let checked = 0, bad = 0;
for (const [L, i] of [[0, 0], [4, 17], [8, 45], [10, 89], [6, 60], [2, 33]]) {
  const png = decodePng(readFileSync(OUT + fireFiles[L].name + "-atlas.png")), fresh = renderFire(L, i);
  for (let y = 0; y < H; y++) for (let x = 0; x < W * 4; x++) { checked++; if (png.data[(y * png.w + i * W) * 4 + x] !== fresh[y * W * 4 + x]) bad++; }
}
// 이음매: 3초 뒤(90번째 장)가 0번째 장과 같은지
const a = renderFire(4, 0), fxb = createFx(campfire, { x: OX, y: OY, light: GLOW, height: LEVEL_H[4], girth: girthAt(LEVEL_H[4]) }), fb = createFrame(W, H), b = new Uint8ClampedArray(W * H * 4);
fxb.update(3); fxb.draw(fb); composite(fb, b, null, 1);
let seam = 0; for (let k = 0; k < a.length; k++) if (a[k] !== b[k]) seam++;
console.log(JSON.stringify({ levels: fireFiles.length, totalBytes: fireFiles.reduce((s, f) => s + f.bytes, 0), roundTrip: { checkedBytes: checked, mismatched: bad }, loopSeamMismatchedBytes: seam }));
