import { createServer } from 'node:http';
import { readFile, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { chromium } from 'playwright';

const root = path.resolve('site');
const suffix = process.env.GITHUB_RUN_ID || Date.now().toString();
const prefix = `qa-web-${suffix}`;
const result = { passed: [], failed: [], screenshots: [] };
const check = (name, value) => (value ? result.passed : result.failed).push(name);
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const file = path.resolve(root, '.' + decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname));
    if (!file.startsWith(root + path.sep)) throw new Error('path');
    const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.json': 'application/json', '.png': 'image/png', '.webp': 'image/webp', '.gif': 'image/gif' };
    await stat(file);
    res.setHeader('Content-Type', types[path.extname(file)] || 'application/octet-stream');
    res.end(await readFile(file));
  } catch { res.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(4173, '127.0.0.1', resolve));
const run = args => new Promise((resolve, reject) => {
  const p = spawn('npx', ['--no-install', 'agent-browser', ...args], { stdio: 'inherit' });
  p.on('error', reject); p.on('exit', code => code === 0 ? resolve() : reject(new Error('agent-browser ' + code)));
});
let browser;
try {
  await run(['open', 'http://127.0.0.1:4173']);
  await run(['wait', '--load', 'networkidle']);
  await run(['snapshot', '-i']);
  await run(['screenshot', `${prefix}-agent-browser.png`]);
  await run(['close']);
  browser = await chromium.launch();
  for (const [name, viewport] of [['desktop',{width:1440,height:1000}],['mobile',{width:390,height:844}]]) {
    const context = await browser.newContext({ viewport });
    const page = await context.newPage();
    const errors = [], failedResources = [];
    page.on('pageerror', e => errors.push(e.message));
    page.on('response', r => { if (r.status() >= 400 && !r.url().endsWith('/favicon.ico')) failedResources.push(r.url()); });
    await page.goto('http://127.0.0.1:4173', { waitUntil:'networkidle' });
    check(`${name}: meaningful heading`, await page.locator('h1').innerText().then(t=>t.trim().length>5));
    check(`${name}: no horizontal overflow`, await page.evaluate(()=>document.documentElement.scrollWidth <= innerWidth+1));
    check(`${name}: no JavaScript error`, errors.length===0);
    // The capture image is optional before a Windows candidate has passed.
    check(`${name}: required resources load`, failedResources.filter(u=>!u.endsWith('/assets/app-screen.png')).length===0);
    check(`${name}: actual character loaded`, await page.evaluate(()=>{
      const sprite=document.querySelector('#character-sprite'), image=document.querySelector('#character-art');
      return Boolean(sprite && !sprite.hidden && getComputedStyle(sprite).backgroundImage!=='none' || image && !image.hidden && image.naturalWidth>0);
    }));
    const manifest = JSON.parse(await readFile(path.join(root,'releases.json'),'utf8'));
    const download = page.locator('#download-button');
    check(`${name}: download truth`, await download.getAttribute('aria-disabled') === (manifest.current.status==='available' ? 'false' : 'true'));
    await page.keyboard.press('Tab');
    check(`${name}: keyboard skip link`, await page.evaluate(()=>document.activeElement?.classList.contains('skip-link')));
    await page.keyboard.press('Enter');
    if (name==='mobile') {
      await page.locator('.menu-toggle').click();
      check('mobile: menu opens', await page.locator('.menu-toggle').getAttribute('aria-expanded')==='true');
      await page.locator('#site-nav a').first().click();
      check('mobile: navigation closes menu', await page.locator('.menu-toggle').getAttribute('aria-expanded')==='false');
    }
    await page.evaluate(()=>window.scrollTo(0,0));
    const screenshot=`${prefix}-${name}.png`;
    await page.screenshot({path:screenshot,fullPage:true}); result.screenshots.push(screenshot);
    await page.emulateMedia({reducedMotion:'reduce'});
    check(`${name}: reduced motion`, await page.evaluate(()=>{
      const s=document.querySelector('#character-sprite');
      return !s || getComputedStyle(s).animationName==='none' || parseFloat(getComputedStyle(s).animationDuration)<=.01;
    }));
    await context.close();
  }
} catch(e) { result.failed.push(String(e)); }
finally {
  await browser?.close();
  await new Promise(resolve=>server.close(resolve));
  await writeFile(`${prefix}-result.json`, JSON.stringify(result,null,2));
}
console.log(JSON.stringify(result));
if(result.failed.length) process.exitCode=1;
