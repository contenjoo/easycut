// Renders the promo page (index.html) frame by frame with headless Chrome and pipes it to ffmpeg.
//
//   python3 music.py music.wav
//   node render.mjs ko video video-ko.mp4          # 1920x1080, 30 fps, no audio
//   node render.mjs ko stills 5,11.2,33.8          # PNGs in stills/ for checking a moment
//   ffmpeg -i video-ko.mp4 -i music.wav -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k \
//          -af volume=-3.5dB -shortest -movflags +faststart ../easycut-promo.mp4
//
// Needs playwright-core (PLAYWRIGHT_CORE=/path/to/playwright-core/index.mjs, or installed next to this file),
// Google Chrome (CHROME=...), ffmpeg, and Python with numpy. Fonts: Noto Sans KR installed.
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const { chromium } = await import(process.env.PLAYWRIGHT_CORE || 'playwright-core');
const dir = path.dirname(fileURLToPath(import.meta.url));
const [lang = 'ko', mode = 'stills', arg = '', fpsArg = '30'] = process.argv.slice(2);

const browser = await chromium.launch({
  executablePath: process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  args: ['--allow-file-access-from-files', '--force-color-profile=srgb', '--hide-scrollbars', '--font-render-hinting=none'],
});
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
page.on('pageerror', e => console.error('PAGE ERROR', e.message));
page.on('console', m => { if (m.type() === 'error') console.error('CONSOLE', m.text()); });
await page.goto(`file://${dir}/index.html?lang=${lang}`);
await page.waitForFunction('window.__ready === true');

if (mode === 'stills') {
  mkdirSync(`${dir}/stills`, { recursive: true });
  for (const t of arg.split(',').map(Number)) {
    await page.evaluate(t => window.render(t), t);
    await page.screenshot({ path: `${dir}/stills/${lang}-${t.toFixed(2)}.png` });
  }
} else {
  const fps = Number(fpsArg), dur = await page.evaluate('window.DURATION'), total = Math.round(dur * fps);
  const ff = spawn('ffmpeg', ['-y', '-hide_banner', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-i', '-',
    '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-tune', 'animation',
    '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-movflags', '+faststart', arg],
    { stdio: ['pipe', 'inherit', 'inherit'] });
  const t0 = Date.now();
  for (let f = 0; f < total; f++) {
    await page.evaluate(t => window.render(t), f / fps);
    const buf = await page.screenshot({ type: 'png' });
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (f % 150 === 0) console.log(`${lang} frame ${f}/${total} (${((Date.now() - t0) / 1000).toFixed(0)}s)`);
  }
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
  console.log('done', arg);
}
await browser.close();
