
import { createRenderer } from "./renderer.js";
import { initWasm } from "./shim.js";
import { createAudio } from "./audio.js";

const ATLAS_URL = "CGA8x8thick.png";


const colorTable = [
  [1.00, 1.00, 1.00, 1], // white
  [0.20, 0.80, 0.20, 1], // green
  [1.00, 0.92, 0.35, 1], // yellow
  [0.90, 0.15, 0.15, 1], // red
  [0.95, 0.50, 0.10, 1], // orange
  [0.75, 0.80, 0.10, 1], // chartreuse
  [0.20, 0.78, 0.20, 1], // green
  [0.10, 0.75, 0.55, 1], // teal
  [0.10, 0.70, 0.85, 1], // cyan
  [0.20, 0.35, 0.90, 1], // blue
  [0.45, 0.20, 0.85, 1], // indigo
  [0.72, 0.20, 0.80, 1], // purple
  [0.90, 0.20, 0.55, 1], // magenta
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
