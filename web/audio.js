export function createAudio() {
  let ctx = null;
  let wasmMemory = null;
  let recipeIndexPtr = 0;
  let recipeDataPtr = 0;
  let instrStride = 16;

  function ensureContext() {
    if (!ctx) ctx = new AudioContext();
    if (ctx.state === "suspended") ctx.resume();
  }

  // Resume AudioContext on user gesture (browsers require this)
  for (const ev of ["keydown", "mousedown", "touchstart"]) {
    document.addEventListener(ev, ensureContext);
  }

  function load(wasm) {
    wasmMemory = wasm.memory;
    recipeIndexPtr = wasm.getRecipeIndexPtr();
    recipeDataPtr = wasm.getRecipeDataPtr();
    instrStride = wasm.getInstructionStride();
  }

  const paramNames = ["frequency", "detune", "gain", "Q", "pan", "delayTime"];
  const waveTypes = ["sine", "square", "sawtooth", "triangle"];
  const filterTypes = ["lowpass", "highpass", "bandpass"];

  function play(soundId, pan, pitchShift, gainScale) {
    if (!ctx || ctx.state !== "running") return false;
    if (!wasmMemory) return false;

    const mem = wasmMemory.buffer;
    const idxView = new DataView(mem, recipeIndexPtr + soundId * 8, 8);
    const offset = idxView.getUint32(0, true);
    const count = idxView.getUint32(4, true);

    const baseTime = ctx.currentTime + 0.005;
    const pitchMult = Math.pow(2, pitchShift / 12);
    const nodes = [];

    // Master panner routes all connectOutput calls through spatial positioning
    const panner = ctx.createStereoPanner();
    panner.pan.value = Math.max(-1, Math.min(1, pan));
    panner.connect(ctx.destination);

    for (let i = 0; i < count; i++) {
      const addr = recipeDataPtr + (offset + i) * instrStride;
      const v = new DataView(mem, addr, instrStride);

      const opcode = v.getUint8(0);
      const arg1 = v.getUint8(1);
      const arg2 = v.getUint8(2);
      const arg3 = v.getUint8(3);
      const farg1 = v.getFloat32(4, true);
      const farg2 = v.getFloat32(8, true);
      const farg3 = v.getFloat32(12, true);

      switch (opcode) {
        case 0: { // create_oscillator
          const osc = ctx.createOscillator();
          osc.type = waveTypes[arg1] || "sine";
          nodes.push(osc);
          break;
        }
        case 1: // create_gain
          nodes.push(ctx.createGain());
          break;
        case 2: { // create_biquad_filter
          const filter = ctx.createBiquadFilter();
          filter.type = filterTypes[arg1] || "lowpass";
          nodes.push(filter);
          break;
        }
        case 3: // create_stereo_panner
          nodes.push(ctx.createStereoPanner());
          break;
        case 4: // create_delay
          nodes.push(ctx.createDelay(farg1 || 1.0));
          break;
        case 5: // create_buffer_source
          nodes.push(ctx.createBufferSource());
          break;
        case 6: { // set_value
          const pName = paramNames[arg2];
          let val = farg1;
          if (pName === "frequency") val *= pitchMult;
          if (pName === "gain") val *= gainScale;
          nodes[arg1][pName].setValueAtTime(val, baseTime + farg2);
          break;
        }
        case 7: { // linear_ramp
          const pName = paramNames[arg2];
          let val = farg1;
          if (pName === "frequency") val *= pitchMult;
          if (pName === "gain") val *= gainScale;
          nodes[arg1][pName].linearRampToValueAtTime(val, baseTime + farg2);
          break;
        }
        case 8: { // exp_ramp
          const pName = paramNames[arg2];
          let val = farg1;
          if (pName === "frequency") val *= pitchMult;
          if (pName === "gain") val *= gainScale;
          nodes[arg1][pName].exponentialRampToValueAtTime(
            Math.max(val, 0.001), baseTime + farg2
          );
          break;
        }
        case 9: { // set_target
          const pName = paramNames[arg2];
          let val = farg1;
          if (pName === "frequency") val *= pitchMult;
          if (pName === "gain") val *= gainScale;
          nodes[arg1][pName].setTargetAtTime(val, baseTime + farg2, farg3);
          break;
        }
        case 10: // connect
          nodes[arg1].connect(nodes[arg2]);
          break;
        case 11: { // connect_param
          const pName = paramNames[arg3];
          nodes[arg1].connect(nodes[arg2][pName]);
          break;
        }
        case 12: // connect_output
          nodes[arg1].connect(panner);
          break;
        case 13: // start
          nodes[arg1].start(baseTime + farg1);
          break;
        case 14: // stop
          nodes[arg1].stop(baseTime + farg1);
          break;
      }
    }
    return true;
  }

  return { play, load };
}
