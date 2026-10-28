#!/usr/bin/env node
export {connect, main} from './cue.mjs';
import {main} from './cue.mjs';
import {pathToFileURL} from 'node:url';
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main(process.argv.slice(2)).catch(error => { console.error(error.message); process.exitCode = 1; });
