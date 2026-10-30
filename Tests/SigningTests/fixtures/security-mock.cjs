// Stands in for the macOS `security` tool so import_signing_identity.sh can be exercised without
// touching a real keychain. State lives in MOCK_STATE; SCENARIO is a comma-separated list of:
//   "<subcommand>-failed"  that subcommand exits 1 ("list-keychains-set-failed" fails only `-s`)
//   a key of `listings`    changes what `find-identity` reports
const fs = require("node:fs");
const path = require("node:path");

const state = process.env.MOCK_STATE;
const scenarios = (process.env.SCENARIO || "ok").split(",");
const args = process.argv.slice(2);
const [command] = args;

const developerId = ["0123456789ABCDEF0123456789ABCDEF01234567", "Developer ID Application: Test Person (TB3Z5R7SY8)"];
const listings = {
  ok: [developerId],
  "mixed-identities": [
    ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "Apple Development: Test Person (TB3Z5R7SY8)"],
    developerId,
  ],
  "duplicate-identity": [developerId, developerId],
  "multiple-identities": [
    developerId,
    ["FEDCBA9876543210FEDCBA9876543210FEDCBA98", "Developer ID Application: Other Person (TB3Z5R7SY8)"],
  ],
  "wrong-team": [["0123456789ABCDEF0123456789ABCDEF01234567", "Developer ID Application: Test Person (WRONGTEAM1)"]],
  "apple-development": [["0123456789ABCDEF0123456789ABCDEF01234567", "Apple Development: Test Person (TB3Z5R7SY8)"]],
  "installer-only": [["0123456789ABCDEF0123456789ABCDEF01234567", "Developer ID Installer: Test Person (TB3Z5R7SY8)"]],
  "no-identity": [],
};

fs.appendFileSync(path.join(state, "calls.jsonl"), `${JSON.stringify(args)}\n`);

const listFile = path.join(state, "search-list");
const readList = () => fs.readFileSync(listFile, "utf8").split("\n").filter(Boolean);
const writeList = (items) => fs.writeFileSync(listFile, items.map((item) => `${item}\n`).join(""));
const option = (name) => args[args.indexOf(name) + 1];
const last = args[args.length - 1];
const fail = (message) => {
  console.error(`security: ${command}: ${message}`);
  process.exit(1);
};
const requireKeychain = (keychain) => {
  if (!fs.existsSync(keychain)) fail(`${keychain} does not exist`);
};

if (scenarios.includes(`${command}-failed`)) fail("simulated failure");
if (scenarios.includes("list-keychains-set-failed") && args.includes("-s")) fail("simulated failure");

switch (command) {
  case "list-keychains":
    if (args.includes("-s")) {
      writeList(args.slice(args.indexOf("-s") + 1));
    } else {
      for (const item of readList()) console.log(`    "${item}"`);
    }
    break;
  case "create-keychain":
    fs.writeFileSync(last, "", { mode: 0o600 });
    break;
  case "set-keychain-settings":
  case "unlock-keychain":
  case "set-key-partition-list":
    requireKeychain(last);
    break;
  case "import":
    requireKeychain(option("-k"));
    fs.copyFileSync(args[1], path.join(state, "imported.p12"));
    break;
  case "find-identity": {
    requireKeychain(last);
    const found = scenarios.map((scenario) => listings[scenario]).find(Boolean) ?? listings.ok;
    found.forEach(([hash, name], index) => console.log(`  ${index + 1}) ${hash} "${name}"`));
    console.log(`     ${found.length} valid identities found`);
    break;
  }
  case "delete-keychain":
    requireKeychain(last);
    fs.rmSync(last);
    writeList(readList().filter((item) => item !== last));
    break;
  default:
    fail("unexpected subcommand");
}
