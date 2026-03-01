export async function initWasm(path, renderer, audio) {
  let instance;

  function clear() { renderer.clear(0,0,0,1) }
  function draw(dstPtr, srcPtr, colorPtr, count, srcW, srcH, dstW, dstH) {
    const mem = instance.exports.memory.buffer;
    const buffers = [
      new Float32Array(mem, dstPtr, count * 2),
      new Uint8Array(mem, srcPtr, count * 1),
      new Uint8Array(mem, colorPtr, count * 1),
    ];
    renderer.draw(buffers, count, srcW, srcH, dstW, dstH);
  }

  function playSound(soundId, pan, pitchShift, gainScale) {
    return audio.play(soundId, pan, pitchShift, gainScale) ? 1 : 0;
  }

  const imports = {
    render: { clear, draw },
    audio: { playSound }
  }

  const module = await WebAssembly.instantiateStreaming(fetch(path), imports);
  instance = module.instance;

  return instance.exports;
}
