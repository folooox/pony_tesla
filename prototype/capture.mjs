import http from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { chromium } from 'playwright';
import assert from 'node:assert/strict';

const files={ '/':'index.html','/index.html':'index.html','/style.css':'style.css','/app.js':'app.js' };
const types={html:'text/html; charset=utf-8',css:'text/css',js:'text/javascript'};
const server=http.createServer(async(req,res)=>{
  const file=files[new URL(req.url,'http://localhost').pathname];
  if(!file){res.writeHead(404);return res.end()}
  res.writeHead(200,{'Content-Type':types[file.split('.').at(-1)]});
  res.end(await readFile(new URL(file,import.meta.url)));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const origin=`http://127.0.0.1:${server.address().port}`;
const browser=await chromium.launch({headless:true});
const errors=[];
try{
  await mkdir('screenshots',{recursive:true});
  const context=await browser.newContext({viewport:{width:393,height:852},deviceScaleFactor:2,reducedMotion:'reduce'});
  const page=await context.newPage();
  page.on('pageerror',error=>errors.push(error.message));
  for(const name of ['vehicle','trips','charging','profile','detail']){
    await page.goto(`${origin}/?page=${name}`);
    await page.evaluate(()=>document.fonts.ready);
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,`${name} horizontal layout`);
    await page.screenshot({path:`screenshots/${name}.png`});
    console.log(`Captured ${name}`);
  }
  await page.goto(origin);
  await page.getByRole('button',{name:'编辑',exact:true}).click();
  await page.getByRole('button',{name:'哨兵',exact:true}).last().click();
  await page.getByRole('button',{name:'闪灯',exact:true}).click();
  await page.getByRole('button',{name:'完成',exact:true}).click();
  assert.equal(await page.locator('.quick-controls').innerText().then(s=>s.includes('闪灯')),true);
  await page.reload();
  assert.equal(await page.locator('.quick-controls').innerText().then(s=>s.includes('闪灯')),true);
  await page.evaluate(()=>localStorage.clear());
  await page.goto(`${origin}/?page=trips`);
  await page.locator('.trip-card').click();
  assert.equal(await page.locator('[data-screen="detail"]').count(),1);
  await page.getByRole('button',{name:'功率',exact:true}).click();
  assert.match(await page.locator('#chart-value').innerText(),/kW/);
  await page.goto(`${origin}/?page=charging`);
  await page.locator('#charge-limit').fill('90');
  assert.equal(await page.locator('#limit-value').innerText(),'90%');
  await page.goto(`${origin}/?page=profile`);
  await page.getByRole('button',{name:/行程数据管理/}).click();
  assert.equal(await page.getByRole('dialog').count(),1);
  const board=await context.newPage();
  await board.setViewportSize({width:1800,height:1130});
  await board.goto(`${origin}/?view=board`);
  await board.evaluate(()=>document.fonts.ready);
  await board.screenshot({path:'screenshots/overview.png',fullPage:true});
  assert.deepEqual(errors,[]);
  console.log('Captured overview; navigation, control customization persistence, chart tabs, charging slider and data sheet verified.');
}finally{await browser.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve))}
