import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const root=new URL('../native/Sources/CallAssistant/Resources/AgentDependencies/',import.meta.url);
test('provider downloads are independent, pinned, and integrity locked',async()=>{
  for(const [provider,adapter,other] of [['codex','codex-acp','@anthropic-ai/'],['claude','claude-agent-acp','@openai/']]) {
    const read=async name=>JSON.parse(await readFile(new URL(`${provider}/${name}`,root),'utf8'));
    const manifest=await read('package.json'),lock=await read('package-lock.json');
    assert.deepEqual(Object.keys(manifest.dependencies),[`@agentclientprotocol/${adapter}`]);
    assert.match(Object.values(manifest.dependencies)[0],/^\d+\.\d+\.\d+$/);
    assert.deepEqual(lock.packages[''].dependencies,manifest.dependencies);
    for(const [name,pkg] of Object.entries(lock.packages)) {
      if(!name)continue;
      assert.ok(!name.includes(other),`${provider} bundles another provider: ${name}`);
      assert.ok(pkg.resolved.startsWith('https://registry.npmjs.org/'),name);
      assert.match(pkg.integrity,/^sha512-/,name);
    }
  }
});
