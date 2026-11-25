const fs = require('fs');
const path = require('path');
const solc = require('solc');

const HERE = __dirname;
const LIBBASE = path.join(HERE, '..', 'node_modules', '@openzeppelin', 'contracts');
const FILES = ['External.sol', 'QQAIToken.sol', 'QQAIMint.sol', 'QQAIVesting.sol', 'QQAIDeployer.sol'];

const sources = {};
for (const f of FILES) sources[f] = { content: fs.readFileSync(path.join(HERE, f), 'utf8') };

const input = {
  language: 'Solidity',
  sources,
  settings: {
    viaIR: true,
    optimizer: { enabled: true, runs: 200 },
    evmVersion: 'cancun',
    outputSelection: { '*': { '*': ['abi', 'evm.bytecode', 'evm.deployedBytecode', 'metadata'] } },
  },
};

function findImport(p) {
  const full = path.join(LIBBASE, p.replace('@openzeppelin/contracts/', ''));
  return fs.existsSync(full) ? { contents: fs.readFileSync(full, 'utf8') } : { error: 'not found: ' + p };
}

const out = JSON.parse(solc.compile(JSON.stringify(input), { import: findImport }));
let errors = 0;
let warnings = 0;
for (const e of out.errors || []) {
  if (e.severity === 'error') { errors++; console.error(e.formattedMessage); }
  else if (e.severity === 'warning') { warnings++; console.warn(e.formattedMessage); }
}
console.log(`solc ${solc.version()} | errors ${errors} | warnings ${warnings}`);
if (errors) process.exit(1);

const buildDir = path.join(HERE, 'build');
fs.mkdirSync(buildDir, { recursive: true });
fs.writeFileSync(path.join(buildDir, 'sourcify-standard-input.json'), JSON.stringify(input, null, 2));
for (const file of FILES) {
  for (const [name, artifact] of Object.entries(out.contracts[file] || {})) {
    const runtimeBytes = artifact.evm.deployedBytecode.object.length / 2;
    console.log(`${name}: runtime ${runtimeBytes} bytes`);
    fs.writeFileSync(path.join(buildDir, `${name}.abi.json`), JSON.stringify(artifact.abi));
    fs.writeFileSync(path.join(buildDir, `${name}.bytecode.txt`), '0x' + artifact.evm.bytecode.object);
  }
}
