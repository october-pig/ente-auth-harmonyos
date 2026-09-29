// Independent adversarial cases against production orchestration. Synthetic only.
import { assert, assertEquals, assertRejects, describe, it } from '../framework.mjs';
import { readFileSync, existsSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { __resetPreferences, __resetRdb } from '../shims/kit-arkdata.mjs';
import { __resetHuks } from '../shims/kit-huks.mjs';
import { resetHttp, setHttpHandler, requestLog } from '../shims/kit-network.mjs';
import { fileIo } from '../shims/kit-corefile.mjs';
const root = '../gen/entry/src/main/ets/';
const { Configuration } = await import(root+'account/Configuration.ts');
const { UserService } = await import(root+'account/UserService.ts');
const { Preferences } = await import(root+'storage/Preferences.ts');
const { AuthenticatorDB } = await import(root+'storage/AuthenticatorDB.ts');
const { OfflineAuthenticatorDB } = await import(root+'storage/OfflineAuthenticatorDB.ts');
const { AuthenticatorService, AccountMode } = await import(root+'services/AuthenticatorService.ts');
const { CodeStore } = await import(root+'store/CodeStore.ts');
const { CryptoUtil } = await import(root+'crypto/CryptoUtil.ts');
const { EventBus } = await import(root+'events/EventBus.ts');
const cfg = () => Configuration.instance;
const svc = () => AuthenticatorService.instance;
const response = (status=200, body={}) => ({responseCode:status,result:JSON.stringify(body)});
function deferred() { let resolve; const promise = new Promise(r=>{resolve=r;}); return {promise,resolve}; }
const turn = () => new Promise(r=>setImmediate(r));
const fixture = JSON.stringify('otpauth://totp/Ente%20Test:review?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Ente%20Test');
async function account(id=1) {
  await cfg().setEmail(`synthetic-${id}@example.test`); await cfg().setUserId(id);
  await cfg().setKey(CryptoUtil.generateKey());
  await cfg().setAuthSecretKey(CryptoUtil.bin2base64(CryptoUtil.generateKey()));
  await cfg().setToken(`SYNTHETIC_${id}`);
}
async function reset() {
  EventBus.clear(); __resetPreferences(); __resetRdb(); __resetHuks(); resetHttp();
  await Preferences.init({}); await AuthenticatorDB.init({}); await OfflineAuthenticatorDB.init({});
  await cfg().init(); await account();
}
async function pending() { return svc().addEntry(fixture,false,AccountMode.online); }
async function remote(id='remote',time=1000) {
  const e=await CryptoUtil.encryptData(CryptoUtil.strToBin(fixture),cfg().getAuthSecretKey());
  return {id,encryptedData:CryptoUtil.bin2base64(e.encryptedData),header:CryptoUtil.bin2base64(e.header),
    isDeleted:false,createdAt:time,updatedAt:time};
}

describe('Independent review — account and data safety',()=>{
  it('F1 delayed SRP repair cannot set up replacement account credentials',async()=>{
    await reset(); const gate=deferred(), entered=deferred(); let setups=0;
    setHttpHandler(async req=>{
      if(req.url.includes('/srp/attributes')) { entered.resolve(); await gate.promise; return response(404); }
      if(req.url.includes('/srp/setup')) {setups++; return response(500);}
      return response();
    });
    const repair=UserService.registerSrpForExistingUsers(cfg().getEmail(),new Uint8Array(32).fill(3));
    await entered.promise; await cfg().logout(); await account(2); gate.resolve(); await repair;
    assertEquals(setups,0,'stale repair must stop before authenticated mutation');
    assertEquals(cfg().getToken(),'SYNTHETIC_2');
  });
  it('F2 overlapping logout responses cannot clear a later login',async()=>{
    await reset(); const gates=[deferred(),deferred()]; let requests=0;
    setHttpHandler(async()=>{ const i=requests++; await gates[i].promise; return response(i===0?200:401); });
    const a=UserService.logout(), b=UserService.logout();
    await turn(); gates[0].resolve(); await a; await account(2); gates[1].resolve(); await b;
    assertEquals(cfg().getToken(),'SYNTHETIC_2'); assertEquals(requests,1,'logout must be coalesced');
  });
  it('F3 pending online code blocks remote logout and preserves ciphertext/key',async()=>{
    await reset(); await pending(); const before=cfg().getAuthSecretKey();
    setHttpHandler(async()=>response());
    await assertRejects(()=>UserService.logout());
    assertEquals(requestLog.length,0,'do not revoke before pending-data protection');
    assertEquals((await AuthenticatorDB.getAll()).length,1);
    assertEquals(cfg().getAuthSecretKey(),before);
    assertEquals((await CodeStore.instance.getAllCodes(AccountMode.online))[0].hasError,false);
  });
  it('F3 direct local cleanup cannot bypass pending-data protection',async()=>{
    await reset(); await pending(); await assertRejects(()=>cfg().logout());
    assertEquals((await AuthenticatorDB.getAll()).length,1); assert(cfg().getAuthSecretKey());
  });
  it('F6 401 closes authenticated admission and retains pending data for recovery',async()=>{
    await reset(); await pending(); const key=cfg().getAuthSecretKey();
    setHttpHandler(async()=>response(401));
    assertEquals(await svc().onlineSync(),false);
    assertEquals(cfg().hasConfiguredAccount(),false,'expired session cannot remain an authenticated Home');
    assertEquals((await AuthenticatorDB.getAll()).length,1); assertEquals(cfg().getAuthSecretKey(),key);
    await cfg().init(); assertEquals(cfg().hasConfiguredAccount(),false,'expiry persists across restart');
  });
  it('new sync is not admitted while local logout is suspended in storage',async()=>{
    await reset(); const e=await remote(); const entered=deferred(),gate=deferred();
    const original=Preferences.clear;
    Preferences.clear=async()=>{entered.resolve();await gate.promise;await original();};
    setHttpHandler(async()=>response(200,{diff:[e]}));
    try {
      const exiting=cfg().logout(); await entered.promise;
      const late=svc().onlineSync(); await turn(); gate.resolve(); await Promise.all([exiting,late]);
      assertEquals(requestLog.length,0,'closed admission must precede asynchronous cleanup');
      assertEquals((await AuthenticatorDB.getAll()).length,0);
      assertEquals(await Preferences.has('lastEntitySyncTime'),false);
    } finally {gate.resolve();Preferences.clear=original;}
  });
  it('F5 499 early tombstones plus a tied boundary tombstone cannot hide a live code',async()=>{
    await reset(); await cfg().optForOfflineMode(); await svc().addEntry(fixture,false,AccountMode.offline);
    const rows=Array.from({length:499},(_,i)=>({id:`deleted-${i}`,isDeleted:true,createdAt:i+1,updatedAt:i+1}));
    rows.push({id:'boundary',isDeleted:true,createdAt:1000,updatedAt:1000}); rows.push(await remote('live-tie',1000));
    let posts=0;
    setHttpHandler(async req=>{
      if(req.method==='POST'){posts++;return response(500);}
      const url=new URL(req.url),since=Number(url.searchParams.get('sinceTime')),limit=Number(url.searchParams.get('limit'));
      return response(200,{diff:rows.filter(e=>e.updatedAt>since).slice(0,limit)});
    });
    for(let i=0;i<3;i++) await CodeStore.instance.importOfflineCodes();
    assertEquals(posts,0); assertEquals((await AuthenticatorDB.getAll()).length,1);
    assertEquals((await OfflineAuthenticatorDB.getAll()).length,0);
  });
});

// Execute the production saveFile body without rendering ArkUI. SDK fs.writeSync:
// default length is buffer length; return value is actual bytes written. No UI evidence.
async function saveThroughProduction(content, {partial=Infinity,fail=false,initial=0}={}) {
  let bytes=new Uint8Array(initial),position=0,closed=0;
  const saved={...fileIo};
  Object.assign(fileIo,{
    OpenMode:{WRITE_ONLY:1,READ_WRITE:2,CREATE:64,TRUNC:512},
    openSync(_uri,mode){ if(mode&512)bytes=new Uint8Array();return {fd:1}; },
    writeSync(_fd,buffer,options){ if(fail)throw new Error('synthetic disk full');
      const input=new Uint8Array(buffer),n=Math.min(options?.length??input.length,partial);
      const output=new Uint8Array(Math.max(bytes.length,position+n));output.set(bytes);output.set(input.subarray(0,n),position);
      bytes=output;position+=n;return n; },
    closeSync(){closed++;},fsyncSync(){},
  });
  try {
    const source=readFileSync(new URL('../../../entry/src/main/ets/pages/ExportPage.ets',import.meta.url),'utf8');
    let body=source.slice(source.indexOf('  private async saveFile('),source.indexOf('  private async exportEncrypted('));
    body=stripTypeScriptTypes(body.replace('private async saveFile','async function saveFile'));
    const encodeBody=stripTypeScriptTypes(source.slice(source.indexOf('function utf8Encode('),source.indexOf('function systemShareLauncher(')));
    const encode=new Function(encodeBody+';return utf8Encode;')();
    let writer;
    if(existsSync(new URL('../gen/entry/src/main/ets/storage/ExportFileWriter.ts',import.meta.url)))
      writer=(await import(root+'storage/ExportFileWriter.ts')).ExportFileWriter;
    const fn=new Function('fs','picker','getContext','utf8Encode','Toast','S','ExportFileWriter',body+';return saveFile;')(
      fileIo,{DocumentViewPicker:class{async save(){return ['synthetic'];}}},()=>({}),encode,
      {show(){}},{export(){return 'export';}},writer);
    let error;
    try {await fn({fileName:'synthetic.json',content});}catch(e){error=e;}
    return {bytes,closed,error};
  } finally {for(const k of Object.keys(fileIo))delete fileIo[k];Object.assign(fileIo,saved);}
}
describe('Independent review — actual export writer contract',()=>{
  it('F4 short UTF-8 payload writes exact byte length and valid JSON',async()=>{
    const content=JSON.stringify({fixture:'公开 synthetic '.repeat(5)});
    const r=await saveThroughProduction(content);
    assertEquals(r.bytes.length,Buffer.byteLength(content));assertEquals(JSON.parse(new TextDecoder().decode(r.bytes)),JSON.parse(content));
    assertEquals(r.closed,1);assert(!r.error);
  });
  it('F4 short writes advance by bytes actually written and truncate an older file',async()=>{
    const content='synthetic payload';const r=await saveThroughProduction(content,{partial:3,initial:999});
    assertEquals(new TextDecoder().decode(r.bytes),content);assertEquals(r.closed,1);assert(!r.error);
  });
  it('F4 an exception still closes the opened descriptor',async()=>{
    const r=await saveThroughProduction('synthetic',{fail:true});assert(r.error);assertEquals(r.closed,1);
  });
});

const { Events } = await import(root+'events/EventBus.ts');
const { RootSessionController } = await import(root+'account/RootSessionController.ts');
const { Router } = await import(root+'pages/Router.ts');
const { LoginResponse } = await import(root+'account/UserService.ts');
const { EnteExport } = await import(root+'services/EnteExport.ts');
const { ImportService } = await import(root+'services/ImportService.ts');
function strictDiff(rows) {
  return async req => {
    if(req.method!=='GET')return response(500);
    const u=new URL(req.url),since=Number(u.searchParams.get('sinceTime')),limit=Number(u.searchParams.get('limit'));
    return response(200,{diff:rows.filter(r=>r.updatedAt>since).sort((a,b)=>a.updatedAt-b.updatedAt).slice(0,limit)});
  };
}
function shell() {
  let state='home', depth=3, changes=0;
  Router.setStack({clear(){depth=0;}});
  Router.setRootHost({showAuthenticatedRoot(){state='home';changes++;},showOnboardingRoot(){state='onboarding';changes++;},
    showSessionRecoveryRoot(){state='recovery';changes++;}});
  return {read:()=>({state,depth,changes}),controller:new RootSessionController()};
}
describe('Review hardening — production root and account transition orchestration',()=>{
  it('401 reaches the mounted production root, clears pushed routes and releases listener identities',async()=>{
    await reset();await pending();const root=shell();
    for(let i=0;i<100;i++){root.controller.mount();root.controller.unmount();}
    root.controller.mount();root.controller.mount();
    try {
      assertEquals(EventBus.listenerCount(Events.TRIGGER_LOGOUT),1);
      assertEquals(EventBus.listenerCount(Events.SIGNED_OUT),1);
      setHttpHandler(async()=>response(401));await svc().onlineSync();
      assertEquals(root.read(),{state:'recovery',depth:0,changes:1});
      assertEquals((await svc().getEntities(AccountMode.online)).length,1);
      const count=requestLog.length;await svc().onlineSync();assertEquals(requestLog.length,count);
    } finally {root.controller.unmount();Router.clearRootHost();}
    assertEquals(EventBus.listenerCount(Events.TRIGGER_LOGOUT),0);
    assertEquals(EventBus.listenerCount(Events.SIGNED_OUT),0);
  });
  it('expiry before root mount is recovered from persisted startup state',async()=>{
    await reset();await cfg().expireSession(cfg().getAccountRevision());await cfg().init();
    const root=shell();try {root.controller.mount();assertEquals(root.read().state,'recovery');assertEquals(root.read().depth,0);}
    finally {root.controller.unmount();Router.clearRootHost();}
  });
  it('a stale 401 cannot expire the replacement account',async()=>{
    await reset();const gate=deferred(),entered=deferred();
    setHttpHandler(async()=>{entered.resolve();await gate.promise;return response(401);});
    const sync=svc().onlineSync();await entered.promise;await cfg().logout();await account(2);
    gate.resolve();await sync;assertEquals(cfg().hasConfiguredAccount(),true);assertEquals(cfg().getToken(),'SYNTHETIC_2');
  });
  it('new credentials and local mutations cannot enter while remote logout is pending',async()=>{
    await reset();const gate=deferred(),entered=deferred();
    setHttpHandler(async()=>{entered.resolve();await gate.promise;return response();});
    const exit=UserService.logout();await entered.promise;
    try {
      const login=new LoginResponse();login.id=2;login.token='SYNTHETIC_2';
      await assertRejects(()=>UserService.saveLoginResponse(login,cfg()));
      await assertRejects(()=>cfg().setToken('SYNTHETIC_2'));
      await assertRejects(()=>pending());assertEquals(await svc().onlineSync(),false);
    } finally {gate.resolve();await exit;}
    assertEquals(cfg().getToken(),undefined);assertEquals((await AuthenticatorDB.getAll()).length,0);
  });
  it('logout drains an already admitted local insert before checking pending data',async()=>{
    await reset();const insert=AuthenticatorDB.insert,gate=deferred(),entered=deferred();
    AuthenticatorDB.insert=async(...args)=>{entered.resolve();await gate.promise;return insert(...args);};
    try {
      const write=pending();await entered.promise;
      const exit=UserService.logout();const rejected=assertRejects(()=>exit);
      gate.resolve();await write;await rejected;
      assertEquals(requestLog.length,0);assertEquals((await AuthenticatorDB.getAll()).length,1);
      assertEquals(cfg().hasConfiguredAccount(),true);
    }finally{gate.resolve();AuthenticatorDB.insert=insert;}
  });
  it('an encryption continuation arriving after logout cannot restore an online row',async()=>{
    await reset();const encrypt=CryptoUtil.encryptData,gate=deferred(),entered=deferred();
    CryptoUtil.encryptData=async(...args)=>{const data=await encrypt(...args);entered.resolve();await gate.promise;return data;};
    try {
      const add=pending();const rejected=assertRejects(()=>add);await entered.promise;await cfg().logout();gate.resolve();await rejected;
      assertEquals((await AuthenticatorDB.getAll()).length,0);
    } finally {gate.resolve();CryptoUtil.encryptData=encrypt;}
  });
  it('an edited remote row blocks logout just like a new local code',async()=>{
    await reset();await AuthenticatorDB.insertOrReplace([await remote()]);
    const row=(await AuthenticatorDB.getAll())[0];await svc().updateEntry(row.generatedID,fixture,false,AccountMode.online);
    await assertRejects(()=>UserService.logout());assertEquals(requestLog.length,0);
    assertEquals((await svc().getEntities(AccountMode.online))[0].hasSynced,false);
  });
  it('expired pending data only admits same-account re-login and survives completion/restart',async()=>{
    await reset();await pending();const key=cfg().getKey(),secret=CryptoUtil.generateKey(),dataKey=cfg().getAuthSecretKey();
    await cfg().expireSession(cfg().getAccountRevision());
    const wrong=new LoginResponse();wrong.id=2;wrong.token='SYNTHETIC_2';
    await assertRejects(()=>UserService.saveLoginResponse(wrong,cfg()));
    assertEquals(cfg().getAuthSecretKey(),dataKey);
    const same=new LoginResponse();same.id=1;same.token='SYNTHETIC_REFRESH';
    await UserService.saveLoginResponse(same,cfg());
    assertEquals(await svc().onlineSync(),false);
    await cfg().init();assertEquals(cfg().hasConfiguredAccount(),false,'incomplete installation persists');
    await cfg().installAccountKeys(cfg().getAccountRevision(),key,secret,'SYNTHETIC_REFRESH');
    await cfg().init();assertEquals(cfg().hasConfiguredAccount(),true);
    assertEquals((await svc().getEntities(AccountMode.online))[0].hasSynced,false);
    assertEquals(cfg().getAuthSecretKey(),dataKey);
  });
  it('an OTT response issued before logout cannot resurrect that login',async()=>{
    await reset();const gate=deferred(),entered=deferred();
    setHttpHandler(async()=>{entered.resolve();await gate.promise;return response(200,{id:1,token:'SYNTHETIC_LATE'});});
    const login=UserService.verifyEmail('synthetic-1@example.test','000000',undefined);
    const rejected=assertRejects(()=>login);await entered.promise;await cfg().logout();await account(2);
    gate.resolve();await rejected;assertEquals(cfg().getToken(),'SYNTHETIC_2');
  });
});

describe('Review hardening — strict timestamp pagination and pending edits',()=>{
  it('first corrected sync repairs an old gap already behind a later persisted cursor',async()=>{
    await reset();const missed=await remote('missed',1000),later=await remote('later',2000);
    await AuthenticatorDB.insertOrReplace([later]);await Preferences.setInt('lastEntitySyncTime',2000);
    setHttpHandler(strictDiff([missed,later]));assertEquals(await svc().onlineSync(),true);
    assertEquals((await AuthenticatorDB.getAll()).length,2);
    assertEquals(await Preferences.getBool('sync_tie_cursor_v1'),true);
    const ids=(await AuthenticatorDB.getAll()).map(r=>r.generatedID);
    await svc().onlineSync();assertEquals((await AuthenticatorDB.getAll()).map(r=>r.generatedID),ids,'unchanged replay does not churn IDs');
  });
  it('a 501-row equal timestamp bucket grows the fetch window without skipping its tail',async()=>{
    await reset();const live=await remote('tail',1000);
    const rows=Array.from({length:500},(_,i)=>({id:`t-${i}`,isDeleted:true,createdAt:1000,updatedAt:1000}));rows.push(live);
    setHttpHandler(strictDiff(rows));assertEquals(await svc().onlineSync(),true);
    assertEquals((await AuthenticatorDB.getAll())[0].id,'tail');
    assert(requestLog.some(r=>new URL(r.url).searchParams.get('limit')==='1000'));
  });
  it('a saturated maximum timestamp bucket fails closed on every retry',async()=>{
    await reset();const rows=Array.from({length:5001},(_,i)=>({id:`t-${i}`,isDeleted:true,createdAt:1000,updatedAt:1000}));
    setHttpHandler(strictDiff(rows));assertEquals(await svc().onlineSync(),false);
    assertEquals(await Preferences.getBool('sync_tie_cursor_v1'),false);
    assertEquals(await svc().onlineSync(),false);
    assert(requestLog.every(r=>Number(new URL(r.url).searchParams.get('sinceTime'))<1000));
    assert(requestLog.length<20,'bounded, no infinite retry loop');
  });
  it('overlap/full replay cannot overwrite or tombstone pending local edits',async()=>{
    await reset();const r=await remote();await AuthenticatorDB.insertOrReplace([r]);
    const id=(await AuthenticatorDB.getAll())[0].generatedID;
    await svc().updateEntry(id,fixture.replace('review','edited'),false,AccountMode.online);
    const edited=(await AuthenticatorDB.getAll())[0];
    setHttpHandler(strictDiff([r]));assertEquals(await svc().onlineSync(),false,'synthetic push fails');
    assertEquals((await AuthenticatorDB.getAll())[0].encryptedData,edited.encryptedData);
    setHttpHandler(strictDiff([{...r,isDeleted:true}]));await svc().onlineSync();
    assertEquals((await AuthenticatorDB.getAll())[0].encryptedData,edited.encryptedData);
    assertEquals((await AuthenticatorDB.getAll())[0].shouldSync,true);
  });
  it('a delayed upload acknowledgement retains a concurrent edit and attaches the assigned ID',async()=>{
    await reset();const id=await pending(),gate=deferred(),entered=deferred();
    setHttpHandler(async req=>{
      if(req.method==='POST'){entered.resolve();await gate.promise;const p=JSON.parse(req.extraData);return response(200,{id:'assigned',...p,createdAt:1,updatedAt:1});}
      return response(200,{diff:[]});
    });
    const sync=svc().onlineSync();await entered.promise;
    await svc().updateEntry(id,fixture.replace('review','edited'),false,AccountMode.online);
    const edited=(await AuthenticatorDB.getAll())[0];gate.resolve();await sync;
    const saved=(await AuthenticatorDB.getAll())[0];assertEquals(saved.encryptedData,edited.encryptedData);
    assertEquals(saved.shouldSync,true);assertEquals(saved.id,'assigned');
    await assertRejects(()=>cfg().logout());
  });
});

describe('Review hardening — exported bytes are consumed by the real importer',()=>{
  it('encrypted export through production saveFile and writer parses/decrypts with the real importer',async()=>{
    await reset();await cfg().optForOfflineMode();await pending();await cfg().expireSession(cfg().getAccountRevision());
    const exported=await EnteExport.exportEncrypted('SYNTHETIC_PUBLIC_BACKUP_PASSWORD',{});
    const written=await saveThroughProduction(exported.content,{partial:17,initial:4096});
    assert(!written.error);assertEquals(written.bytes.length,Buffer.byteLength(exported.content));
    const codes=await ImportService.parseEnteEncrypted(new TextDecoder().decode(written.bytes),'SYNTHETIC_PUBLIC_BACKUP_PASSWORD');
    assertEquals(codes.length,1);assertEquals(codes[0].issuer,'Ente Test');assertEquals(codes[0].account,'review');
  });
  it('a zero-byte write fails without spinning and closes the descriptor',async()=>{
    const r=await saveThroughProduction('synthetic',{partial:0});assert(r.error);assertEquals(r.closed,1);
  });
  it('a multi-chunk Unicode payload has exact bytes across the 1 MiB boundary',async()=>{
    const content='公开🧪'.repeat(120000);const r=await saveThroughProduction(content,{partial:700003});
    assert(!r.error);assertEquals(r.bytes.length,Buffer.byteLength(content));assertEquals(new TextDecoder().decode(r.bytes),content);
  });
});

describe('Review hardening — refused logout preserves outstanding upload acknowledgement',()=>{
  it('refusing logout while POST is pending must not invalidate its acknowledgement and cause a second POST',async()=>{
    await reset();await pending();const gate=deferred(),entered=deferred();let posts=0;let uploaded;
    setHttpHandler(async req=>{
      if(req.method==='POST'){posts++;entered.resolve();await gate.promise;uploaded={id:'uploaded',...JSON.parse(req.extraData),createdAt:10,updatedAt:10};return response(200,uploaded);}
      const u=new URL(req.url);return response(200,{diff:uploaded&&uploaded.updatedAt>Number(u.searchParams.get('sinceTime'))?[uploaded]:[]});
    });
    const sync=svc().onlineSync();await entered.promise;
    await assertRejects(()=>UserService.logout());gate.resolve();await sync;
    await svc().onlineSync();assertEquals(posts,1,'refused logout must not convert accepted POST to an unacknowledged retry');
    assertEquals((await AuthenticatorDB.getAll()).length,1);
    assertEquals((await AuthenticatorDB.getAll())[0].shouldSync,false);
  });
});

describe('Review hardening — delayed SRP mutation continuations',()=>{
  it('a delayed setup reply cannot complete SRP against a replacement account',async()=>{
    await reset();const gate=deferred(),entered=deferred();let completes=0;
    setHttpHandler(async req=>{
      if(req.url.includes('/srp/attributes'))return response(404);
      if(req.url.includes('/srp/setup')){entered.resolve();await gate.promise;return response(200,{setupID:'synthetic',srpB:'BQ=='});}
      if(req.url.includes('/srp/complete')){completes++;return response();}
      return response(500);
    });
    const repair=UserService.registerSrpForExistingUsers(cfg().getEmail(),new Uint8Array(32).fill(3));
    await entered.promise;await cfg().logout();await account(2);gate.resolve();await repair;
    assertEquals(completes,0);assertEquals(cfg().getToken(),'SYNTHETIC_2');
    const setup=requestLog.find(r=>r.url.includes('/srp/setup'));
    assertEquals(setup.header['X-Auth-Token'],'SYNTHETIC_1','original credentials only');
  });
});
