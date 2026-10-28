import { build } from 'esbuild';
import { mkdir, copyFile } from 'node:fs/promises';
const out = '../native/Sources/CallAssistant/Resources/Canvas';
await mkdir(out, { recursive: true });
await build({ entryPoints: ['src/main.jsx'], bundle: true, minify: true, outfile: `${out}/canvas.js`, platform: 'browser', target: 'safari17', define: { 'process.env.NODE_ENV': '"production"' } });
for (const name of ['index.html', 'canvas.css']) await copyFile(`src/${name}`, `${out}/${name}`);
