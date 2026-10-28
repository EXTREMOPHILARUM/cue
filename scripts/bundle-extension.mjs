import {cpSync, mkdirSync, mkdtempSync, readdirSync, renameSync, rmSync} from 'node:fs';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';

export function bundleExtension(destination,root=fileURLToPath(new URL('../',import.meta.url))) {
  destination=path.resolve(destination);
  if(destination===path.resolve(root))throw new Error('Bundle destination must differ from the source');
  mkdirSync(path.dirname(destination),{recursive:true});
  const stage=mkdtempSync(path.join(path.dirname(destination),'.extension-'));
  try {
    for(const name of readdirSync(root)) {
      if(name==='manifest.json' || /\.(js|html|css)$/.test(name))cpSync(path.join(root,name),path.join(stage,name));
    }
    for(const name of ['icons','docs/licenses'])cpSync(path.join(root,name),path.join(stage,path.basename(name)),{recursive:true});
    rmSync(destination,{recursive:true,force:true});
    renameSync(stage,destination);
  } finally {rmSync(stage,{recursive:true,force:true});}
}
if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href) {
  if(!process.argv[2])throw new Error('Expected bundle destination');
  bundleExtension(process.argv[2]);
}
