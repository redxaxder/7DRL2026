// renderer.js — WebGL2 batched sprite renderer

function buildVertexShader(colorTable) {
    const entries = colorTable.map(c =>
        `    vec4(${c[0].toFixed(6)}, ${c[1].toFixed(6)}, ${c[2].toFixed(6)}, ${c[3].toFixed(6)})`
    ).join(',\n');

    return `#version 300 es
layout(location = 0) in vec2 a_position;
layout(location = 1) in vec2 a_destXY;
layout(location = 2) in float a_srcIdx;
layout(location = 3) in float a_colorIdx;
uniform vec2 u_resolution;
uniform vec2 u_dstSize;

out vec2 v_uv;
out vec4 v_tint;
flat out float v_layer;

const vec4 colorTable[${colorTable.length}] = vec4[${colorTable.length}](
${entries}
);

void main() {
    vec2 pos = a_destXY + a_position * u_dstSize;
    vec2 clip = (pos / u_resolution) * 2.0 - 1.0;
    clip.y = -clip.y;
    gl_Position = vec4(clip, 0.0, 1.0);

    v_uv = a_position;
    v_layer = a_srcIdx;
    v_tint = colorTable[int(a_colorIdx)];
}
`;
}

const FRAG_SRC = `#version 300 es
precision mediump float;

in vec2 v_uv;
in vec4 v_tint;
flat in float v_layer;

uniform highp sampler2DArray u_atlas;
uniform highp vec2 u_srcSize;

out vec4 fragColor;

void main() {
    // Convert UV to texel-space
    vec2 uv_texels = v_uv * u_srcSize - 0.5;

    // Base texel and fractional offset
    vec2 base = floor(uv_texels);
    vec2 fr = uv_texels - base;

    // Fat-pixel blend weights: sharp inside texels, smooth at seams
    vec2 aa = fwidth(uv_texels);
    vec2 blend = clamp((fr - 0.5) / aa + 0.5, 0.0, 1.0);

    // Fetch 4 neighbors (clamped to layer bounds)
    int layer = int(v_layer);
    vec2 maxCoord = u_srcSize - 1.0;
    vec4 t00 = texelFetch(u_atlas, ivec3(clamp(base,              vec2(0.0), maxCoord), layer), 0);
    vec4 t10 = texelFetch(u_atlas, ivec3(clamp(base + vec2(1, 0), vec2(0.0), maxCoord), layer), 0);
    vec4 t01 = texelFetch(u_atlas, ivec3(clamp(base + vec2(0, 1), vec2(0.0), maxCoord), layer), 0);
    vec4 t11 = texelFetch(u_atlas, ivec3(clamp(base + vec2(1, 1), vec2(0.0), maxCoord), layer), 0);

    // Manual bilinear blend with fat-pixel weights
    vec4 texel = mix(mix(t00, t10, blend.x), mix(t01, t11, blend.x), blend.y);
    vec4 color = texel * v_tint;
    if (color.a < 0.01) discard;
    fragColor = color;
}
`;


function compileShader(gl, type, src) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, src);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        const log = gl.getShaderInfoLog(shader);
        gl.deleteShader(shader);
        throw new Error(`Shader compile error: ${log}`);
    }
    return shader;
}

function createProgram(gl, vertSrc) {
    const vs = compileShader(gl, gl.VERTEX_SHADER, vertSrc);
    const fs = compileShader(gl, gl.FRAGMENT_SHADER, FRAG_SRC);
    const prog = gl.createProgram();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
        const log = gl.getProgramInfoLog(prog);
        gl.deleteProgram(prog);
        throw new Error(`Program link error: ${log}`);
    }
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    return prog;
}

export async function createRenderer(canvas, atlasUrl, maxSprites, colorTable, spriteW, spriteH) {
    const gl = canvas.getContext("webgl2", {
        alpha: false,
        premultipliedAlpha: false,
    });
    if (!gl) throw new Error("WebGL2 not supported");

    // Compile shaders and program
    const vertSrc = buildVertexShader(colorTable);
    const program = createProgram(gl, vertSrc);
    const u_resolution = gl.getUniformLocation(program, "u_resolution");
    const u_atlas = gl.getUniformLocation(program, "u_atlas");
    const u_srcSize = gl.getUniformLocation(program, "u_srcSize");
    const u_dstSize = gl.getUniformLocation(program, "u_dstSize");

    // Static unit quad VBO
    const quadVBO = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, quadVBO);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);

    // destXY VBO
    const destVBO = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, destVBO);
    gl.bufferData(gl.ARRAY_BUFFER, maxSprites * 2 * 4, gl.DYNAMIC_DRAW);

    // srcIdx VBO
    const srcVBO = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, srcVBO);
    gl.bufferData(gl.ARRAY_BUFFER, maxSprites * 1, gl.DYNAMIC_DRAW);

    // colorIdx VBO
    const colorVBO = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, colorVBO);
    gl.bufferData(gl.ARRAY_BUFFER, maxSprites * 1, gl.DYNAMIC_DRAW);

    // VAO
    const vao = gl.createVertexArray();
    gl.bindVertexArray(vao);

    // Attr 0: unit quad position (per-vertex)
    gl.bindBuffer(gl.ARRAY_BUFFER, quadVBO);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);

    // a_destXY (location 1)
    gl.bindBuffer(gl.ARRAY_BUFFER, destVBO);
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 2, gl.FLOAT, false, 0, 0);
    gl.vertexAttribDivisor(1, 1);

    // a_srcIdx (location 2)
    gl.bindBuffer(gl.ARRAY_BUFFER, srcVBO);
    gl.enableVertexAttribArray(2);
    gl.vertexAttribPointer(2, 1, gl.UNSIGNED_BYTE, false, 0, 0);
    gl.vertexAttribDivisor(2, 1);

    // a_colorIdx (location 3)
    gl.bindBuffer(gl.ARRAY_BUFFER, colorVBO);
    gl.enableVertexAttribArray(3);
    gl.vertexAttribPointer(3, 1, gl.UNSIGNED_BYTE, false, 0, 0);
    gl.vertexAttribDivisor(3, 1);

    gl.bindVertexArray(null);

    // Atlas texture
    const texture = gl.createTexture();

    // Blending
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    async function loadAtlas(url) {
        const img = await new Promise((resolve, reject) => {
            const i = new Image();
            i.onload = () => resolve(i);
            i.onerror = () => reject(new Error(`Failed to load atlas: ${url}`));
            i.src = url;
        });

        const cols = Math.floor(img.width / spriteW);
        const rows = Math.floor(img.height / spriteH);
        const numLayers = cols * rows;

        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D_ARRAY, texture);
        gl.texStorage3D(gl.TEXTURE_2D_ARRAY, 1, gl.RGBA8, spriteW, spriteH, numLayers);

        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);

        const tmp = document.createElement("canvas");
        tmp.width = spriteW;
        tmp.height = spriteH;
        const ctx = tmp.getContext("2d");

        for (let i = 0; i < numLayers; i++) {
            const col = i % cols;
            const row = Math.floor(i / cols);
            ctx.clearRect(0, 0, spriteW, spriteH);
            ctx.drawImage(img, col * spriteW, row * spriteH, spriteW, spriteH, 0, 0, spriteW, spriteH);
            gl.texSubImage3D(gl.TEXTURE_2D_ARRAY, 0, 0, 0, i, spriteW, spriteH, 1, gl.RGBA, gl.UNSIGNED_BYTE, tmp);
        }

        gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

        return { layers: numLayers };
    }

    function resize() {
        const dpr = window.devicePixelRatio || 1;
        const w = Math.round(canvas.clientWidth * dpr);
        const h = Math.round(canvas.clientHeight * dpr);
        if (canvas.width !== w || canvas.height !== h) {
            canvas.width = w;
            canvas.height = h;
        }
        gl.viewport(0, 0, canvas.width, canvas.height);
    }

    function clear(r, g, b, a) {
        gl.clearColor(r, g, b, a);
        gl.clear(gl.COLOR_BUFFER_BIT);
    }

    function clearRect(x, y, w, h, colorIdx) {
        const c = colorTable[colorIdx];
        gl.enable(gl.SCISSOR_TEST);
        gl.scissor(x, canvas.height - y - h, w, h);
        gl.clearColor(c[0], c[1], c[2], c[3]);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.disable(gl.SCISSOR_TEST);
    }

    function scissor(x,y,w,h) {
        gl.enable(gl.SCISSOR_TEST);
        gl.scissor(x, canvas.height - y - h, w, h);
    }

    function unscissor() {
        gl.disable(gl.SCISSOR_TEST);
    }

    function draw(buffers, spriteCount, srcW, srcH, dstW, dstH) {
        if (spriteCount === 0) return;

        gl.useProgram(program);
        gl.uniform2f(u_resolution, canvas.width, canvas.height);
        gl.uniform1i(u_atlas, 0);
        gl.uniform2f(u_srcSize, srcW, srcH);
        gl.uniform2f(u_dstSize, dstW, dstH);

        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D_ARRAY, texture);

        gl.bindBuffer(gl.ARRAY_BUFFER, destVBO);
        gl.bufferSubData(gl.ARRAY_BUFFER, 0, buffers[0]);

        gl.bindBuffer(gl.ARRAY_BUFFER, srcVBO);
        gl.bufferSubData(gl.ARRAY_BUFFER, 0, buffers[1]);

        gl.bindBuffer(gl.ARRAY_BUFFER, colorVBO);
        gl.bufferSubData(gl.ARRAY_BUFFER, 0, buffers[2]);

        gl.bindVertexArray(vao);
        gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, spriteCount);
        gl.bindVertexArray(null);
    }

    // Load initial atlas if provided
    if (atlasUrl) {
        await loadAtlas(atlasUrl);
    }

    return {
        loadAtlas,
        resize,
        clear,
        clearRect,
        scissor,
        unscissor,
        draw,
        gl,
        canvas,
    };
}
