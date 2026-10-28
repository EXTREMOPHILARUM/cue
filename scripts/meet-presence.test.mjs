import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const source=await readFile(new URL('../meet-presence.js',import.meta.url),'utf8');
test('pre-join microphone/self preview is not a joined call; visible joined controls or an actual participant self marker are',()=>{
 const scope=vm.createContext({getComputedStyle:()=>({display:'block',visibility:'visible'})});vm.runInContext(source,scope);
 const button=(label,text='',visible=true)=>({getAttribute:key=>key==='aria-label'?label:'',textContent:text,getClientRects:()=>visible?[{}]:[]});
 let markers=[],buttons=[button('Turn off microphone')];
 const document={querySelectorAll:selector=>selector.startsWith('[data-participant-id]')?markers:buttons};
 assert.equal(scope.CallAssistantMeetPresence(document),false);
 buttons.push(button('Leave call'));assert.equal(scope.CallAssistantMeetPresence(document),true);
 buttons=[button('Leave call','',false)];assert.equal(scope.CallAssistantMeetPresence(document),false);
 markers=[button('')];assert.equal(scope.CallAssistantMeetPresence(document),true);
 markers=[];buttons=[button('','call_end')];assert.equal(scope.CallAssistantMeetPresence(document),true);
});
