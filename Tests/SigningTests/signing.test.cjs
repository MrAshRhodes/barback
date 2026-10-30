const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const root = path.resolve(__dirname, "../..");

function fixture(t, scenario = "accepted") {
  const dir = mkdtempSync(path.join(tmpdir(), "barback-signing-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const bin = path.join(dir, "bin");
  const app = path.join(dir, "Barback.app");
  mkdirSync(bin);
  mkdirSync(app);
  const log = path.join(dir, "calls");
  writeFileSync(log, "");
  const command = (name, body) => writeFileSync(path.join(bin, name),
    `#!/bin/bash\nset -eu\nprintf '%s\\n' "${name} $*" >> "$CALLS"\n${body}\n`, { mode: 0o755 });
  command("codesign", `
if [[ "$*" == *--verify* ]]; then
  [[ "$*" == *'-R=identifier "io.github.mrashrhodes.barback"'* ]] || exit 8
  [[ "$SCENARIO" != bad-requirement ]] || exit 9
elif [[ "$*" == *--requirements* ]]; then
  echo 'designated => test requirement'
else
  if [[ "$SCENARIO" == wrong-team ]]; then
    echo TeamIdentifier=WRONG
  else
    echo TeamIdentifier=TB3Z5R7SY8
  fi
  if [[ "$SCENARIO" != no-timestamp ]]; then echo Timestamp=test; fi
  if [[ "$SCENARIO" == no-x86-runtime && "$*" == *'--arch x86_64'* ]]; then
    echo 'CodeDirectory v=20500 flags=0x0(none)'
  else
    echo 'CodeDirectory v=20500 flags=0x10000(runtime)'
  fi
fi`);
  command("lipo", "echo 'arm64 x86_64'");
  command("ditto", 'touch "${@: -1}"');
  command("spctl", `
[[ "$SCENARIO" != gatekeeper-rejected ]] || exit 1
if [[ "$SCENARIO" == wrong-source ]]; then
  echo 'source=Developer ID'
else
  echo 'source=Notarized Developer ID'
fi`);
  command("xcrun", `
case "$1 $2" in
  '--find notarytool'|'--find stapler') exit 0 ;;
  'notarytool history') [[ "$SCENARIO" != bad-credentials ]]; exit ;;
  'notarytool submit')
    case "$SCENARIO" in
      rejected) echo '{"status":"Invalid","id":"test-id"}' ;;
      timeout) echo '{"status":"In Progress","id":"test-id"}'; exit 1 ;;
      malformed) echo 'not json' ;;
      missing-status) echo '{"id":"test-id"}' ;;
      *) echo '{"status":"Accepted","id":"test-id"}' ;;
    esac ;;
  'notarytool log') echo 'test rejection diagnostic' ;;
  'stapler staple') [[ "$SCENARIO" != staple-failed ]] ;;
  'stapler validate') [[ "$SCENARIO" != ticket-invalid ]] ;;
  *) exit 99 ;;
esac`);
  const env = {
    ...process.env, PATH: `${bin}:${process.env.PATH}`, CALLS: log, SCENARIO: scenario,
    BARBACK_NOTARY_PROFILE: "test-profile", BARBACK_NOTARY_KEYCHAIN: "",
    BARBACK_NOTARY_KEY_PATH: "", BARBACK_NOTARY_KEY_ID: "", BARBACK_NOTARY_ISSUER_ID: "",
    RUNNER_TEMP: dir,
  };
  return {
    app, env,
    run(script = "notarize.sh", args = [app]) {
      return spawnSync("bash", [path.join(root, "Scripts", script), ...args],
        { env, encoding: "utf8", timeout: 10000 });
    },
    calls: () => readFileSync(log, "utf8"),
  };
}

test("accepted submission is stapled then verified, including both architectures", (t) => {
  const f = fixture(t);
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  const calls = f.calls();
  assert.match(calls, /notarytool submit .*--keychain-profile test-profile --wait --timeout 30m/);
  assert.match(calls, /codesign --display --arch arm64/);
  assert.match(calls, /codesign --display --arch x86_64/);
  assert.ok(calls.indexOf("notarytool submit") < calls.indexOf("stapler staple"));
  assert.ok(calls.indexOf("stapler staple") < calls.indexOf("stapler validate"));
  assert.ok(calls.indexOf("stapler validate") < calls.indexOf("spctl --assess"));
});

for (const scenario of ["rejected", "timeout", "malformed", "missing-status"]) {
  test(`${scenario} submission never reaches stapling or Gatekeeper`, (t) => {
    const f = fixture(t, scenario);
    const result = f.run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /notarization did not finish with Accepted/);
    assert.doesNotMatch(f.calls(), /stapler staple|spctl --assess/);
    if (scenario !== "malformed") assert.match(result.stdout, /test rejection diagnostic/);
  });
}

for (const scenario of ["bad-requirement", "wrong-team", "no-timestamp", "no-x86-runtime"]) {
  test(`${scenario} fails before uploading the app`, (t) => {
    const f = fixture(t, scenario);
    assert.notEqual(f.run().status, 0);
    assert.doesNotMatch(f.calls(), /notarytool submit/);
  });
}

for (const scenario of ["staple-failed", "ticket-invalid", "gatekeeper-rejected", "wrong-source"]) {
  test(`${scenario} cannot report success`, (t) => {
    const f = fixture(t, scenario);
    assert.notEqual(f.run().status, 0);
  });
}

test("missing credentials fail before submission", (t) => {
  const f = fixture(t);
  f.env.BARBACK_NOTARY_PROFILE = "";
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /set BARBACK_NOTARY_PROFILE/);
  assert.equal(f.calls(), "");
});

test("credential preflight propagates authentication failure", (t) => {
  const f = fixture(t, "bad-credentials");
  assert.notEqual(f.run("notarize.sh", ["--check-credentials"]).status, 0);
  assert.doesNotMatch(f.calls(), /notarytool submit/);
});

test("production packaging rejects ad-hoc signing before building", (t) => {
  const f = fixture(t);
  f.env.BARBACK_SIGN_IDENTITY = "-";
  const result = f.run("package_release.sh", ["--notarize"]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /requires BARBACK_SIGN_IDENTITY/);
  assert.equal(f.calls(), "");
});

test("ZIPs cannot be stapled directly", (t) => {
  const f = fixture(t);
  const zip = path.join(path.dirname(f.app), "release.zip");
  writeFileSync(zip, "");
  const result = f.run("verify_signature.sh", [zip, "--require-notarized"]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /expected an .app or .dmg/);
  assert.equal(f.calls(), "");
});
