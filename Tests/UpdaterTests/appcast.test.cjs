const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const root = path.resolve(__dirname, "../..");
const tools = path.join(root, ".build/artifacts/sparkle/Sparkle/bin");
// Public RFC 8032 section 7.1 TEST 1 vector, not a release credential.
const seed = Buffer.from("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "hex").toString("base64");
const publicKey = Buffer.from("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "hex").toString("base64");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: "utf8", timeout: 60000, ...options });
  assert.equal(result.status, 0, `${command}: ${result.stderr}\n${result.stdout}`);
  return result.stdout;
}

function fixture(t) {
  assert.ok(fs.existsSync(path.join(tools, "generate_appcast")), "Run make build to resolve Sparkle first");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "barback-appcast-test-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.mkdirSync(path.join(dir, "Scripts"));
  for (const script of ["generate_appcast.sh", "changelog.sh"]) {
    fs.copyFileSync(path.join(root, "Scripts", script), path.join(dir, "Scripts", script));
  }
  fs.mkdirSync(path.join(dir, ".build/artifacts/sparkle/Sparkle"), { recursive: true });
  fs.symlinkSync(tools, path.join(dir, ".build/artifacts/sparkle/Sparkle/bin"));
  fs.writeFileSync(path.join(dir, "CHANGELOG.md"), "# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- Fixture update.\n");
  const app = path.join(dir, "dist/Barback.app");
  fs.mkdirSync(path.join(app, "Contents/MacOS"), { recursive: true });
  fs.copyFileSync("/usr/bin/true", path.join(app, "Contents/MacOS/Barback"));
  const plist = path.join(app, "Contents/Info.plist");
  fs.copyFileSync(path.join(root, "Resources/Info.plist"), plist);
  for (const [key, value] of Object.entries({
    CFBundleIdentifier: `io.github.barback.fixture.${path.basename(dir)}`,
    CFBundleVersion: "999999",
    CFBundleShortVersionString: "1.0.0",
    SUPublicEDKey: publicKey,
  })) {
    run("/usr/bin/plutil", ["-replace", key, "-string", value, plist]);
  }
  run("codesign", ["--force", "--sign", "-", app]);
  const archive = path.join(dir, "dist/Barback-1.0.0.zip");
  run("ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", app, archive]);
  const env = {
    ...process.env, BARBACK_SPARKLE_PRIVATE_KEY: seed, BARBACK_SPARKLE_PUBLIC_KEY: publicKey,
  };
  return {
    dir, archive, env,
    generate: () => spawnSync("bash", [path.join(dir, "Scripts/generate_appcast.sh"), "1.0.0"], {
      env, encoding: "utf8", timeout: 60000,
    }),
  };
}

test("real Sparkle tools sign the final archive/feed; tampering is rejected", (t) => {
  const f = fixture(t);
  const result = f.generate();
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  const feed = path.join(f.dir, "dist/appcast.xml");
  const xml = fs.readFileSync(feed, "utf8");
  assert.match(xml, /https:\/\/github.com\/MrAshRhodes\/barback\/releases\/download\/v1.0.0\/Barback-1.0.0.zip/);
  assert.match(xml, /Fixture update/);
  assert.ok(fs.existsSync(`${feed}.sha256`));
  fs.writeFileSync(feed, xml.replace("Fixture update", "Tampered notes"));
  const verify = spawnSync(path.join(tools, "sign_update"), ["--ed-key-file", "-", "--verify", feed], {
    input: seed, encoding: "utf8", timeout: 10000,
  });
  assert.notEqual(verify.status, 0, "tampered appcast was accepted");
});

test("mismatched embedded public key never produces a publishable feed", (t) => {
  const f = fixture(t);
  f.env.BARBACK_SPARKLE_PUBLIC_KEY = Buffer.alloc(32).toString("base64");
  const result = f.generate();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /archive public key mismatch/);
  assert.ok(!fs.existsSync(path.join(f.dir, "dist/appcast.xml")));
});

test("missing private key fails without a Keychain fallback", (t) => {
  const f = fixture(t);
  f.env.BARBACK_SPARKLE_PRIVATE_KEY = "";
  const result = f.generate();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Missing Sparkle private key/);
  assert.ok(!fs.existsSync(path.join(f.dir, "dist/appcast.xml")));
});
