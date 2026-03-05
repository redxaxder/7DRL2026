
import { createRenderer } from "./renderer.js";
import { initWasm } from "./shim.js";
import { createAudio } from "./audio.js";

const ATLAS_URL = "CGA8x8thick.png";


const colorTable = [
  [1.00, 1.00, 1.00, 1], // 00 white
  [0.20, 0.80, 0.20, 1], // 01 green
  [1.00, 0.92, 0.35, 1], // 02 yellow
  [0.90, 0.15, 0.15, 1], // 03 red
  [0.95, 0.50, 0.10, 1], // 04 orange
  [0.75, 0.80, 0.10, 1], // 05 chartreuse
  [0.20, 0.78, 0.20, 1], // 06 green
  [0.10, 0.75, 0.55, 1], // 07 teal
  [0.10, 0.70, 0.85, 1], // 08 cyan
  [0.20, 0.35, 0.90, 1], // 09 blue
  [0.45, 0.20, 0.85, 1], // 10 indigo
  [0.72, 0.20, 0.80, 1], // 11 purple
  [0.90, 0.20, 0.55, 1], // 12 magenta
  [0.00, 0.00, 0.00, 1], // 13 black
  [0.60, 0.60, 0.60, 1], // 14 gray
  [0.30, 0.30, 0.30, 1], // 15 dark_gray
  [0.55, 0.35, 0.15, 1], // 16 brown
  [1.00, 0.50, 0.70, 1], // 17 pink
  [0.55, 0.10, 0.10, 1], // 18 dark_red
  [0.10, 0.15, 0.50, 1], // 19 dark_blue
  [0.10, 0.45, 0.10, 1], // 20 dark_green
];

async function main() {
  const canvas = document.getElementById("c");
  const DRAW_BUFFER_SIZE = 8192;
  const renderer = await createRenderer(canvas, ATLAS_URL, DRAW_BUFFER_SIZE, colorTable, 8, 8);
  const audio = createAudio();
  let wasm = await initWasm("../zig-out/bin/_7DRL2026.wasm", renderer, audio)
  renderer.resize();
  window.addEventListener("resize", () => {
    renderer.resize();
    wasm.resize(canvas.width, canvas.height);
  });


  function frame(now) {
    wasm.frame(now);
    requestAnimationFrame(frame);
  }

  let success = wasm.init(DRAW_BUFFER_SIZE, canvas.width, canvas.height, colorTable.length);
  console.log("init wasm", success);
  if (success == 0) {
    audio.load(wasm);

    const keyCodeBufPtr = wasm.getKeyCodeBufPtr();
    document.addEventListener("keydown", e => {
      const code = e.code;
      const keyCodeBuf = new Uint8Array(wasm.memory.buffer, keyCodeBufPtr, 32);
      if (code.length > 32) return;
      for (let i = 0; i < code.length; i++) keyCodeBuf[i] = code.charCodeAt(i);
      wasm.keydown(code.length);
      e.preventDefault()
    });
    document.addEventListener("keyup", e => {
      const code = e.code;
      const keyCodeBuf = new Uint8Array(wasm.memory.buffer, keyCodeBufPtr, 32);
      if (code.length > 32) return;
      for (let i = 0; i < code.length; i++) keyCodeBuf[i] = code.charCodeAt(i);
      wasm.keyup(code.length);
    });
    document.addEventListener("blur", () => wasm.clearKeys());


    canvas.addEventListener("mousedown", e => {
      wasm.mousedown(e.button, e.offsetX, e.offsetY);
      e.preventDefault()
    });
    canvas.addEventListener("mouseup", e => {
      wasm.mouseup(e.button);
      e.preventDefault()
    });
    canvas.addEventListener("mousemove", e => {
      wasm.mousemove(e.offsetX, e.offsetY);
      e.preventDefault()
    });
    canvas.addEventListener("mouseout", _ => {
      wasm.mouseout();
    });
    canvas.addEventListener("mouseleave", _ => {
      wasm.mouseout();
    });


    requestAnimationFrame(frame);
  }
}

main().catch(console.error);
