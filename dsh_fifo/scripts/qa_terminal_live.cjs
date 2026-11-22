// Optional browser integration QA. The demo itself needs no Node dependencies.
const assert = require('node:assert/strict');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const os = require('node:os');
const path = require('node:path');
const base=process.env.TERMINAL_URL||'http://127.0.0.1:8765';

(async () => {
  const browser = await chromium.launch({headless:true, executablePath:process.env.CHROME_BIN});
  const page = await browser.newPage({viewport:{width:1440,height:1100},deviceScaleFactor:1});
  const errors=[];
  page.on('pageerror', error=>errors.push(error.message));
  const state=async()=>await (await page.request.get(base+'/api/state')).json();
  async function waitState(predicate, label) {
    // Native Wave redraws slow wall-clock execution; simulated timing is unchanged.
    const until=Date.now()+60000;
    while(Date.now()<until){const s=await state();if(predicate(s)){console.log('PASS: '+label);return s}await page.waitForTimeout(250)}
    throw Error('Timeout: '+label+' '+JSON.stringify(await state()));
  }
  async function quiet(label) {
    const before=await (await page.request.get(base+'/api/runtime')).json();
    const log=await page.locator('#runtime-log').textContent();
    await page.waitForTimeout(1200);
    const after=await (await page.request.get(base+'/api/runtime')).json();
    assert.equal(after.time_ps,before.time_ps);
    assert.equal(after.commands_sent,before.commands_sent);
    assert.equal(after.replies_received,before.replies_received);
    assert.equal(after.commands.bytes,before.commands.bytes);
    assert.equal(after.transcript.bytes,before.transcript.bytes);
    assert.equal(await page.locator('#runtime-log').textContent(),log);
    console.log('PASS: '+label);
  }
  try {
    await page.goto(base+'/');
    await page.locator('#connectionText').filter({hasText:'ModelSim 在线'}).waitFor();
    await page.locator('#runtime-log').filter({hasText:/LIVE (READY|CMD|ACK)/}).waitFor();
    await page.locator('#log-tab-compile').click();
    await page.locator('#runtime-log').filter({hasText:'Errors: 0'}).waitFor();
    await page.locator('#log-tab-commands').click();
    await page.locator('#runtime-log').filter({hasText:'ACK'}).waitFor();
    const runtime=await (await page.request.get(base+'/api/runtime')).json();
    assert.equal(runtime.pid,(await state()).pid);
    assert(runtime.process_running&&runtime.commands_sent===runtime.replies_received);
    assert(runtime.command_line.includes('vsim.exe'));
    console.log('PASS: ModelSim live output, compiler output and real command/reply display');
    if(runtime.mode==='gui'){
      const commands=await (await page.request.get(base+'/api/commands.txt')).text();
      assert(commands.includes('GUI_READY native Transcript/Wave, same live tb_terminal_live instance'));
      assert(!commands.includes('WAVE_ERROR'));
      assert(runtime.command_line.includes('-gui'));
      console.log('PASS: native Transcript/Wave initialized inside the same live simulator');
    }
    await page.locator('#reset').click();
    await waitState(s=>s.totals.sent===0,'reset from browser');
    await page.locator('#run-mode').selectOption('demand');
    await waitState(s=>s.run_mode==='demand'&&s.advancement.state==='idle','on-demand mode is idle after reset');
    await page.locator('#runtime-status').filter({hasText:'空闲 · 已暂停'}).waitFor();
    await page.waitForTimeout(850);
    await quiet('idle page polling advances neither ModelSim time nor Transcript');
    const nonce='网页实测 / 🧪 / <script>仅作为文字显示</script> / '+Date.now();
    await page.locator('#input-a').fill(nonce);
    await page.locator('#send-a').click();
    await waitState(s=>s.delivered.some(m=>m.text===nonce&&m.target==='b'),'typed Unicode received through RTL');
    await page.locator('#messages-b .bubble').filter({hasText:nonce}).waitFor();
    assert.equal(await page.locator('#messages-b script').count(),0);
    await waitState(s=>s.advancement.state==='idle','text delivery finishes CDC settling then pauses');
    await page.locator('#scenario').click();
    await waitState(s=>s.signals.af===1&&s.signals.pending_a>0&&s.delivered.some(m=>m.source==='b'),
      'blocked A-to-B and working B-to-A visible in browser');
    await page.locator('#challenge').click();
    await waitState(s=>s.challenges.length===1&&!s.challenges[0].passed,'challenge remains pending while B paused');
    await waitState(s=>s.advancement.state==='blocked','blocked direction pauses again after reverse challenge delivery');
    await page.locator('#runtime-status').filter({hasText:'堵塞 · 已暂停'}).waitFor();
    await page.waitForTimeout(850);
    await quiet('blocked page stops automatic STEP commands and raw log growth');
    await page.locator('#receive-b').click();
    const drained=await waitState(s=>s.challenges[0]?.passed&&s.totals.received===s.totals.sent,
      'resume drains all frames and passes both random challenges');
    const csv=await (await page.request.get(base+'/api/events.csv')).text();
    assert(csv.includes(',AB,W,')&&csv.includes(',BA,R,'));
    const vcd=await (await page.request.get(base+'/api/wave.vcd')).text();
    assert(vcd.includes('$timescale')&&vcd.includes('wr_gray')&&vcd.includes('clk_a')&&vcd.includes('clk_b'));
    const evidence=await (await page.request.get(base+'/api/evidence.json')).json();
    assert.equal(evidence.totals.received,drained.totals.received);
    assert(evidence.source_hashes['rtl/fifo/async_fifo.v']);
    console.log('PASS: raw CSV, VCD and source-hashed evidence exports');
    await waitState(s=>s.advancement.state==='idle','resuming receive drains traffic then becomes idle');
    await page.locator('#run-mode').selectOption('manual');
    await waitState(s=>s.run_mode==='manual','manual mode selected from browser');
    await page.waitForTimeout(850);
    await quiet('manual mode remains paused');
    const beforeStep=(await state()).time_ps;
    await page.locator('#step').click();
    await waitState(s=>s.time_ps===beforeStep+200000,'manual button advances exactly 200 ns');
    await page.locator('#run-mode').selectOption('continuous');
    await waitState(s=>s.run_mode==='continuous'&&s.time_ps>beforeStep+200000,'continuous mode advances even without traffic');
    await page.locator('#run-mode').selectOption('demand');
    await waitState(s=>s.run_mode==='demand'&&s.advancement.state==='idle','switch back to on-demand pauses idle simulation');
    const unauthorized=await page.request.post(base+'/api/send',{data:{side:'a',text:'unauthorized'}});
    assert.equal(unauthorized.status(),403);
    console.log('PASS: state writes require local page token');

    await page.locator('#stop').click();
    const stopped=await waitState(s=>!s.online&&s.stopped,'stopping ModelSim disables live transport');
    await page.waitForTimeout(800);
    assert.equal((await state()).totals.received,stopped.totals.received);
    assert(await page.locator('#send-a').isDisabled());
    assert(await page.locator('#send-b').isDisabled());
    assert(await page.locator('#scenario').isDisabled());
    await page.locator('#runtime-status').filter({hasText:'进程已退出'}).waitFor();
    await page.locator('#runtime-log').filter({hasText:'QUIT'}).waitFor();
    const runtimeStopped=await (await page.request.get(base+'/api/runtime')).json();
    await page.waitForTimeout(450);
    const runtimeStillStopped=await (await page.request.get(base+'/api/runtime')).json();
    assert.equal(runtimeStopped.commands.bytes,runtimeStillStopped.commands.bytes);
    assert.equal(runtimeStopped.replies_received,runtimeStillStopped.replies_received);
    console.log('PASS: no fabricated delivery and send controls disabled offline');
    await page.locator('#restart').click();
    await waitState(s=>s.online&&s.session!==stopped.session,'restart creates new ModelSim session');
    await page.locator('#scenario').click();
    await waitState(s=>s.signals.af===1&&s.delivered.some(m=>m.source==='b')&&s.advancement.state==='blocked',
      'final demonstration shows real backpressure and automatic pause');
    await page.locator('#runtime-status').filter({hasText:'堵塞 · 已暂停'}).waitFor();
    await page.waitForTimeout(850);
    await page.locator('#log-tab-transcript').click();
    const screenshotRoot = process.env.TERMINAL_SCREENSHOTS || path.join(os.tmpdir(), 'dsh_fifo_browser_qa');
    await page.screenshot({path:path.join(screenshotRoot,'live_preview.png'),fullPage:true});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    await page.setViewportSize({width:390,height:844});
    await page.waitForTimeout(400);
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    await page.screenshot({path:path.join(screenshotRoot,'live_mobile_preview.png'),fullPage:true});
    assert.deepEqual(errors,[]);
    console.log('RESULT: PASS | on-demand idle/blocked/resume, manual/continuous controls, data, offline behavior, desktop/mobile layout; no JS errors');
  } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
