const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const { tmpdir } = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const root = path.resolve(__dirname, "../..");
const script = path.join(root, "Scripts", "import_signing_identity.sh");
const securityMock = path.join(__dirname, "fixtures", "security-mock.cjs");

const IDENTITY = "0123456789ABCDEF0123456789ABCDEF01234567";
const P12 = Buffer.from([0x30, 0x82, 0x00, 0xff, 0x62, 0x61, 0x72, 0x62, 0x61, 0x63, 0x6b, 0x0a]);
const P12_BASE64 = P12.toString("base64");
const P12_PASSWORD = "p12-test-password";
const ORIGINAL_SEARCH_LIST = [
  "/Users/runner/Library/Keychains/login.keychain-db",
  "/Users/runner/Library/Keychains/Other Keychain.keychain-db",
  "/Library/Keychains/System.keychain",
];

const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`;
const lines = (text) => text.split("\n").filter(Boolean);

// Runs the real script under /bin/bash (3.2 on macOS) with a mock `security`, so no run ever
// touches a real keychain.
function fixture(t, scenario = "ok") {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(tmpdir(), "barback-import-test-")));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const bin = path.join(dir, "bin");
  const state = path.join(dir, "state");
  const runner = path.join(dir, "runner-temp");
  for (const name of [bin, state, runner]) fs.mkdirSync(name);
  const searchListFile = path.join(state, "search-list");
  const callsFile = path.join(state, "calls.jsonl");
  const outputFile = path.join(dir, "github-output");
  fs.writeFileSync(searchListFile, ORIGINAL_SEARCH_LIST.map((item) => `${item}\n`).join(""));
  fs.writeFileSync(callsFile, "");
  fs.writeFileSync(path.join(bin, "security"),
    `#!/bin/bash\nexec ${quote(process.execPath)} ${quote(securityMock)} "$@"\n`, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, "uname"),
    '#!/bin/bash\nprintf "%s\\n" "${MOCK_UNAME:-Darwin}"\n', { mode: 0o755 });

  const env = Object.fromEntries(Object.entries(process.env)
    .filter(([name]) => !/^(BARBACK_|GITHUB_|RUNNER_|MOCK_|SCENARIO$)/.test(name)));
  Object.assign(env, {
    PATH: `${bin}:${process.env.PATH}`, RUNNER_TEMP: runner, GITHUB_OUTPUT: outputFile,
    MOCK_STATE: state, SCENARIO: scenario,
    BARBACK_SIGNING_P12_BASE64: P12_BASE64, BARBACK_SIGNING_P12_PASSWORD: P12_PASSWORD,
  });
  const resolved = spawnSync("/bin/bash", ["-c", "command -v security"], { env, encoding: "utf8" });
  assert.equal(resolved.stdout.trim(), path.join(bin, "security"), "tests must never reach the real security tool");

  const outputText = () => (fs.existsSync(outputFile) ? fs.readFileSync(outputFile, "utf8") : "");
  return {
    dir, runner, env, outputText,
    run: (args = []) => spawnSync("/bin/bash", [script, ...args], { env, encoding: "utf8", timeout: 30000 }),
    calls: () => lines(fs.readFileSync(callsFile, "utf8")).map((line) => JSON.parse(line)),
    searchList: () => lines(fs.readFileSync(searchListFile, "utf8")),
    outputs: () => Object.fromEntries(lines(outputText()).map((line) => line.split(/=(.*)/s).slice(0, 2))),
    imported: () => fs.readFileSync(path.join(state, "imported.p12")),
    leftovers: () => fs.readdirSync(runner),
    appendToSearchList: (item) => fs.appendFileSync(searchListFile, `${item}\n`),
  };
}

function assertNoSecrets(f, result, ...extra) {
  const visible = [result.stdout, result.stderr, f.outputText()].join("\n");
  for (const secret of [P12_BASE64, P12_PASSWORD, ...extra]) {
    assert.ok(!visible.includes(secret), "a credential reached stdout, stderr or GITHUB_OUTPUT");
  }
}

const commandNames = (f) => f.calls().map(([command]) => command);

test("imports the identity into an isolated keychain and reports the Developer ID hash", (t) => {
  const f = fixture(t);
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), IDENTITY);

  const outputs = f.outputs();
  assert.deepEqual(Object.keys(outputs), ["keychain", "identity"]);
  assert.equal(outputs.identity, IDENTITY);
  const keychain = outputs.keychain;
  const work = path.dirname(keychain);
  assert.equal(path.dirname(work), f.runner);
  assert.match(path.basename(work), /^barback-signing\.[A-Za-z0-9]{6}$/);
  assert.equal(path.basename(keychain), "barback-signing.keychain-db");
  assert.equal(fs.statSync(work).mode & 0o777, 0o700);
  assert.deepEqual(fs.readdirSync(work), ["barback-signing.keychain-db"], "the PKCS#12 file must not outlive the import");
  assert.deepEqual(f.searchList(), [keychain, ...ORIGINAL_SEARCH_LIST]);
  assert.deepEqual(f.imported(), P12);

  const calls = f.calls();
  assert.deepEqual(calls.map(([command]) => command), [
    "list-keychains", "create-keychain", "set-keychain-settings", "unlock-keychain",
    "import", "set-key-partition-list", "list-keychains", "find-identity",
  ]);
  const password = calls[1][2];
  assert.match(password, /^[0-9a-f]{48}$/);
  assert.notEqual(password, P12_PASSWORD);
  assert.deepEqual(calls[0], ["list-keychains", "-d", "user"]);
  assert.deepEqual(calls[1], ["create-keychain", "-p", password, keychain]);
  assert.deepEqual(calls[2], ["set-keychain-settings", "-lut", "21600", keychain]);
  assert.deepEqual(calls[3], ["unlock-keychain", "-p", password, keychain]);
  assert.deepEqual(calls[4], ["import", path.join(work, "identity.p12"), "-k", keychain,
    "-P", P12_PASSWORD, "-T", "/usr/bin/codesign", "-f", "pkcs12"]);
  assert.deepEqual(calls[5], ["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychain]);
  assert.deepEqual(calls[6], ["list-keychains", "-d", "user", "-s", keychain, ...ORIGINAL_SEARCH_LIST]);
  assert.deepEqual(calls[7], ["find-identity", "-v", "-p", "codesigning", keychain]);
  assertNoSecrets(f, result, password);
});

test("each run gets its own directory and keychain password", (t) => {
  const f = fixture(t);
  assert.equal(f.run().status, 0);
  assert.equal(f.run().status, 0);
  const [first, second] = f.calls().filter(([command]) => command === "create-keychain");
  assert.notEqual(first[2], second[2]);
  assert.notEqual(first[3], second[3]);
});

test("accepts a base64 secret that was wrapped across lines", (t) => {
  const f = fixture(t);
  f.env.BARBACK_SIGNING_P12_BASE64 = `${P12_BASE64.replace(/(.{4})/g, "$1\n")}\n`;
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(f.imported(), P12);
});

for (const scenario of ["mixed-identities", "duplicate-identity"]) {
  test(`${scenario}: only the Developer ID Application identity for the team is selected`, (t) => {
    const f = fixture(t, scenario);
    const result = f.run();
    assert.equal(result.status, 0, result.stderr);
    assert.equal(f.outputs().identity, IDENTITY);
  });
}

const failures = [
  ["create-keychain-failed", /simulated failure/],
  ["set-keychain-settings-failed", /simulated failure/],
  ["unlock-keychain-failed", /simulated failure/],
  ["import-failed", /could not import the PKCS#12 signing identity/],
  ["set-key-partition-list-failed", /simulated failure/],
  ["list-keychains-set-failed", /simulated failure/],
  ["find-identity-failed", /simulated failure/],
  ["no-identity", /no valid Developer ID Application identity for team TB3Z5R7SY8/],
  ["wrong-team", /no valid Developer ID Application identity for team TB3Z5R7SY8/],
  ["apple-development", /no valid Developer ID Application identity for team TB3Z5R7SY8/],
  ["installer-only", /no valid Developer ID Application identity for team TB3Z5R7SY8/],
  ["multiple-identities", /multiple matching Developer ID identities/],
];
for (const [scenario, message] of failures) {
  test(`${scenario} fails closed without leaving a keychain or credentials behind`, (t) => {
    const f = fixture(t, scenario);
    const result = f.run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, message);
    const outputs = f.outputs();
    assert.ok(outputs.keychain, "the keychain is reported before anything can fail");
    assert.equal(outputs.identity, undefined);
    assert.deepEqual(f.leftovers(), []);
    assert.deepEqual(f.searchList(), ORIGINAL_SEARCH_LIST);
    assertNoSecrets(f, result);
  });
}

test("a failed cleanup after a failed import is reported, and the credentials are still removed", (t) => {
  const f = fixture(t, "import-failed,delete-keychain-failed");
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /temporary signing keychain cleanup failed/);
  assert.deepEqual(f.leftovers(), []);
});

for (const [label, name, value, message] of [
  ["a missing PKCS#12 secret", "BARBACK_SIGNING_P12_BASE64", "", /BARBACK_SIGNING_P12_BASE64 is empty/],
  ["a missing password secret", "BARBACK_SIGNING_P12_PASSWORD", "", /BARBACK_SIGNING_P12_PASSWORD is empty/],
  ["invalid base64", "BARBACK_SIGNING_P12_BASE64", "!!!not-base64!!!", /not valid base64/],
  ["a whitespace-only PKCS#12 secret", "BARBACK_SIGNING_P12_BASE64", " \n ", /decoded PKCS#12 file is empty/],
]) {
  test(`${label} fails before any keychain is created`, (t) => {
    const f = fixture(t);
    f.env[name] = value;
    const result = f.run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, message);
    assert.ok(!commandNames(f).some((command) => command === "create-keychain" || command === "import"));
    assert.deepEqual(f.leftovers(), []);
    assertNoSecrets(f, result);
  });
}

test("refuses to run anywhere but macOS", (t) => {
  const f = fixture(t);
  f.env.MOCK_UNAME = "Linux";
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /needs macOS/);
  assert.deepEqual(f.calls(), []);
  assert.deepEqual(f.leftovers(), []);
});

test("requires a usable temporary directory", (t) => {
  const f = fixture(t);
  f.env.RUNNER_TEMP = path.join(f.dir, "missing");
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /temporary directory is not usable/);
  assert.deepEqual(f.calls(), []);
});

test("rejects unexpected arguments", (t) => {
  const f = fixture(t);
  for (const args of [["--cleanup"], ["--cleanup", "a", "b"], ["--unknown"], ["extra"]]) {
    const result = f.run(args);
    assert.notEqual(result.status, 0, args.join(" "));
    assert.match(result.stderr, /usage: Scripts\/import_signing_identity\.sh/);
  }
  assert.deepEqual(f.calls(), []);
});

test("cleanup deletes the keychain and its directory, restores the search list and can be repeated", (t) => {
  const f = fixture(t);
  assert.equal(f.run().status, 0);
  const keychain = f.outputs().keychain;
  const concurrent = "/Users/runner/Library/Keychains/added-later.keychain-db";
  f.appendToSearchList(concurrent);

  const cleanup = f.run(["--cleanup", keychain]);
  assert.equal(cleanup.status, 0, cleanup.stderr);
  assert.equal(fs.existsSync(path.dirname(keychain)), false);
  assert.deepEqual(f.leftovers(), []);
  assert.deepEqual(f.searchList(), [...ORIGINAL_SEARCH_LIST, concurrent]);
  assert.ok(f.calls().some(([command, target]) => command === "delete-keychain" && target === keychain));

  const again = f.run(["--cleanup", keychain]);
  assert.equal(again.status, 0, again.stderr);
});

for (const scenario of ["delete-keychain-failed", "list-keychains-failed"]) {
  test(`${scenario} during cleanup is reported, but the credentials directory is still removed`, (t) => {
    const f = fixture(t);
    assert.equal(f.run().status, 0);
    const keychain = f.outputs().keychain;
    f.env.SCENARIO = scenario;
    const cleanup = f.run(["--cleanup", keychain]);
    assert.notEqual(cleanup.status, 0);
    assert.match(cleanup.stderr, /could not remove the temporary signing keychain/);
    assert.equal(fs.existsSync(path.dirname(keychain)), false);
  });
}

test("cleanup refuses anything but this script's own temporary keychain", (t) => {
  const f = fixture(t);
  const victim = path.join(f.dir, "victim");
  fs.mkdirSync(victim);
  fs.symlinkSync(victim, path.join(f.runner, "barback-signing.linked"));
  const targets = [
    path.join(f.dir, "login.keychain-db"),
    path.join(f.runner, "barback-signing.keychain-db"),
    path.join(f.runner, "other", "barback-signing.keychain-db"),
    path.join(f.runner, "nested", "barback-signing.abcdef", "barback-signing.keychain-db"),
    path.join(f.runner, "barback-signing.abc", "barback-signing.keychain-db"),
    path.join(f.runner, "barback-signing.abcdefg", "barback-signing.keychain-db"),
    path.join(f.runner, "barback-signing.abcdef", "login.keychain-db"),
    path.join(f.runner, "barback-signing.linked", "barback-signing.keychain-db"),
  ];
  for (const target of targets) {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, "keep");
    const result = f.run(["--cleanup", target]);
    assert.notEqual(result.status, 0, target);
    assert.match(result.stderr, /refusing to remove a keychain outside a temporary Barback signing directory/, target);
    assert.equal(fs.readFileSync(target, "utf8"), "keep", target);
  }
  assert.ok(!commandNames(f).includes("delete-keychain"));
});

// The workflow wiring below is checked as text because the repository has no YAML parser.
const workflow = fs.readFileSync(path.join(root, ".github", "workflows", "release.yml"), "utf8");
const jobStart = workflow.indexOf("\n  release:\n");
const jobEnd = workflow.indexOf("\n  tap:\n");
assert.ok(jobStart !== -1 && jobEnd > jobStart, "release.yml must keep its release and tap jobs");
const releaseJob = workflow.slice(jobStart, jobEnd);
const steps = Object.fromEntries(releaseJob.split("\n      - name: ").slice(1).map((block) => {
  const newline = block.indexOf("\n");
  return [block.slice(0, newline), block.slice(newline)];
}));

test("release workflow tests without credentials, signs, cleans up, and only then publishes", () => {
  const order = Object.keys(steps);
  const positions = [
    "Test", "Import the signing identity", "Prepare notarization credentials", "Build and package",
    "Remove notarization credentials", "Remove the signing keychain", "Publish the GitHub release",
  ].map((name) => {
    assert.ok(name in steps, `missing step: ${name}`);
    return order.indexOf(name);
  });
  assert.deepEqual(positions, [...positions].sort((a, b) => a - b));
  assert.match(steps["Remove notarization credentials"], /\n {8}if: always\(\)\n/);
  assert.match(steps["Remove the signing keychain"], /\n {8}if: always\(\) && steps\.signing\.outputs\.keychain != ''\n/);
  assert.match(steps["Remove the signing keychain"], /Scripts\/import_signing_identity\.sh --cleanup "\$KEYCHAIN"/);
  assert.match(steps["Remove notarization credentials"], /rm -f "\$RUNNER_TEMP\/barback-notary\.p8"/);
  assert.doesNotMatch(workflow, /Require an approved CI credential import path/);
});

test("release workflow signs with the imported identity and a protected notarization key", () => {
  const importStep = steps["Import the signing identity"];
  assert.match(importStep, /\n {8}id: signing\n/);
  assert.match(importStep, /run: Scripts\/import_signing_identity\.sh > \/dev\/null/);
  const prepare = steps["Prepare notarization credentials"];
  assert.match(prepare, /umask 077/);
  assert.match(prepare, /base64 --decode > "\$BARBACK_NOTARY_KEY_PATH"/);
  assert.match(prepare, /BARBACK_NOTARY_KEY_PATH="\$RUNNER_TEMP\/barback-notary\.p8"/);
  assert.match(prepare, /Scripts\/notarize\.sh --check-credentials/);
  const build = steps["Build and package"];
  assert.match(build, /BARBACK_SIGN_IDENTITY: \$\{\{ steps\.signing\.outputs\.identity \}\}/);
  assert.match(build, /BARBACK_NOTARY_KEY_PATH: \$\{\{ runner\.temp \}\}\/barback-notary\.p8/);
  assert.match(build, /--formats zip,dmg --require-universal --notarize/);
});

test("release workflow publishes the ZIP and DMG with their checksums", () => {
  const publish = steps["Publish the GitHub release"];
  for (const asset of ["zip", "zip.sha256", "dmg", "dmg.sha256"]) {
    assert.ok(publish.includes(`"dist/Barback-$VERSION.${asset}"`), asset);
  }
});

test("release secrets are only environment entries of the steps that need them", () => {
  const expected = {
    "Import the signing identity": ["BARBACK_SIGNING_P12_BASE64", "BARBACK_SIGNING_P12_PASSWORD"],
    "Prepare notarization credentials": [
      "BARBACK_NOTARY_ISSUER_ID", "BARBACK_NOTARY_KEY_ID", "BARBACK_NOTARY_KEY_P8_BASE64"],
    "Build and package": ["BARBACK_NOTARY_ISSUER_ID", "BARBACK_NOTARY_KEY_ID"],
  };
  for (const [name, body] of Object.entries(steps)) {
    const used = [...body.matchAll(/secrets\.(\w+)/g)].map((match) => match[1]).sort();
    assert.deepEqual(used, expected[name] ?? [], name);
  }
  for (const line of workflow.split("\n").filter((entry) => /\$\{\{\s*secrets\./.test(entry))) {
    assert.match(line, /^\s+([A-Z][A-Z0-9_]*): \$\{\{ secrets\.\1 \}\}$/, line);
  }
  assert.doesNotMatch(workflow, /set\s+-\w*x|xtrace/);
});

test("release workflow keeps write access to the release job and pins its checkouts", () => {
  assert.match(workflow, /^permissions:\n {2}contents: read\n/m);
  assert.match(releaseJob, /\n {4}environment: release\n/);
  assert.match(releaseJob, /\n {4}permissions:\n {6}contents: write\n/);
  const checkouts = workflow.match(/uses: actions\/checkout@/g) ?? [];
  const pinned = workflow.match(/uses: actions\/checkout@[0-9a-f]{40} # v\d+\n {8}with:\n {10}persist-credentials: false\n/g) ?? [];
  assert.equal(pinned.length, checkouts.length);
  assert.ok(checkouts.length >= 2);
});
