const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

const root = path.resolve(__dirname, "../..");
const instructionsPath = path.join(root, ".github", "copilot-instructions.md");

// A developer's global excludes file must not mask a missing rule in the tracked .gitignore.
function git(...args) {
  return spawnSync("git", ["-C", root, "-c", "core.excludesFile=/dev/null", ...args], {
    encoding: "utf8",
  });
}

const inGitCheckout = (() => {
  const result = git("rev-parse", "--is-inside-work-tree");
  return result.status === 0 && result.stdout.trim() === "true";
})();

function requireGit(t) {
  if (inGitCheckout) return true;
  assert.ok(!process.env.GITHUB_ACTIONS, "CI must run the repository checks from a git checkout");
  t.skip("not a git checkout");
  return false;
}

const MUST_BE_IGNORED = [
  "AuthKey_ABCDE12345.p8",
  "signing/DeveloperID.p12",
  "DeveloperID.pfx",
  "private.pem",
  "private.key",
  "developerID_application.cer",
  "CertificateSigningRequest.certSigningRequest",
  "Barback.mobileprovision",
  "Barback.provisionprofile",
  "barback-signing.keychain",
  "barback-signing.keychain-db",
  "BARBACK_SIGNING_P12_BASE64.b64",
  "notary.p8.base64",
  ".env",
  ".env.release",
  "dist/Barback.app/Contents/MacOS/Barback",
  "dist/Barback-1.2.3.zip",
  "Barback.app/Contents/Info.plist",
  "Barback-1.2.3.zip",
  "Barback-1.2.3.zip.sha256",
  "Barback-1.2.3.dmg",
  "Barback-1.2.3.dmg.sha256",
  "Barback.pkg",
  "Barback.xcarchive/Info.plist",
  ".worktrees/feature/README.md",
];

const MUST_STAY_TRACKED = [
  ".github/copilot-instructions.md",
  ".github/workflows/release.yml",
  ".github/workflows/ci.yml",
  "Scripts/package_release.sh",
  "Scripts/import_signing_identity.sh",
  "Scripts/notarize.sh",
  "Scripts/verify_signature.sh",
  "Scripts/update_tap.sh",
  "packaging/signing/designated-requirement.txt",
  "packaging/signing/developer-id-requirement.txt",
  "packaging/homebrew/barback.rb.tmpl",
  "VERSION",
  "CHANGELOG.md",
  "Resources/Barback.entitlements",
  "Tests/SigningTests/fixtures/security-mock.cjs",
];

const FORBIDDEN_TRACKED_PATHS = [
  /(^|\/)\.env(\.|$)/,
  /^dist\//,
  /(^|\/)[^/]+\.(app|xcarchive)\//,
  /\.(p12|pfx|p8|pem|key|cer|certSigningRequest|mobileprovision|provisionprofile|keychain|keychain-db|b64|base64|dmg|pkg)$/i,
  /(^|\/)Barback-[^/]*\.zip(\.sha256)?$/,
];

test("signing material and release artifacts are ignored by the tracked .gitignore", (t) => {
  if (!requireGit(t)) return;
  for (const candidate of MUST_BE_IGNORED) {
    const result = git("check-ignore", "--no-index", "-v", "--", candidate);
    assert.equal(result.status, 0, `${candidate} must be ignored\n${result.stderr}`);
    const match = /^(.*?):(\d+):(.*)\t/.exec(result.stdout);
    assert.ok(match, `unexpected check-ignore output for ${candidate}: ${result.stdout}`);
    assert.equal(match[1], ".gitignore", `${candidate} must be ignored by the tracked .gitignore`);
    assert.ok(!match[3].startsWith("!"), `${candidate} is re-included by ${match[3]}`);
  }
});

test("release-critical sources are never ignored", (t) => {
  if (!requireGit(t)) return;
  for (const tracked of MUST_STAY_TRACKED) {
    assert.ok(fs.existsSync(path.join(root, tracked)), `${tracked} is missing`);
    const result = git("check-ignore", "--no-index", "-q", "--", tracked);
    assert.equal(result.status, 1, `${tracked} must not be ignored\n${result.stderr}`);
  }
  const ignoredTracked = git("ls-files", "-ci", "--exclude-standard");
  assert.equal(ignoredTracked.status, 0, ignoredTracked.stderr);
  assert.equal(ignoredTracked.stdout, "", "tracked files are matched by .gitignore");
});

test("no signing material or release artifacts are tracked", (t) => {
  if (!requireGit(t)) return;
  const listed = git("ls-files", "-z");
  assert.equal(listed.status, 0, listed.stderr);
  const files = listed.stdout.split("\0").filter(Boolean);
  assert.ok(files.length > 0, "git ls-files returned no files");

  for (const file of files) {
    for (const pattern of FORBIDDEN_TRACKED_PATHS) {
      assert.ok(!pattern.test(file), `${file} must not be committed (${pattern})`);
    }
    const absolute = path.join(root, file);
    let stats;
    try {
      stats = fs.statSync(absolute);
    } catch {
      continue;
    }
    if (!stats.isFile() || stats.size > 5 * 1024 * 1024) continue;
    const contents = fs.readFileSync(absolute, "latin1");
    assert.ok(!/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(contents), `${file} contains a private key`);
  }
});

test("Copilot instructions reference real make targets and files", () => {
  assert.ok(fs.existsSync(instructionsPath), ".github/copilot-instructions.md is missing");
  const instructions = fs.readFileSync(instructionsPath, "utf8");
  const makefile = fs.readFileSync(path.join(root, "Makefile"), "utf8");
  const spans = [...instructions.matchAll(/`([^`\n]+)`/g)].map((match) => match[1].trim());
  assert.ok(spans.length > 0, "instructions contain no code spans");

  for (const span of spans) {
    const tokens = span.split(/\s+/);
    if (tokens[0] === "make") {
      for (const target of tokens.slice(1).filter((token) => !token.includes("="))) {
        const escaped = target.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        assert.match(makefile, new RegExp(`^${escaped}:`, "m"), `make ${target} is not a Makefile target`);
      }
    }
    for (const token of tokens) {
      const repoPath =
        /^(\.github|Scripts|packaging|Tests|Sources|Resources|site)\//.test(token) && !/[*<]/.test(token);
      const rootFile = /^(?:[A-Z][A-Za-z]*\.md|Package\.swift|VERSION|Makefile|\.gitignore)$/.test(token);
      if (repoPath || rootFile) {
        assert.ok(fs.existsSync(path.join(root, token.replace(/\/$/, ""))), `${token} does not exist`);
      }
    }
  }

  const designated = fs.readFileSync(
    path.join(root, "packaging", "signing", "designated-requirement.txt"),
    "utf8",
  );
  for (const identity of ["io.github.mrashrhodes.barback", "TB3Z5R7SY8"]) {
    assert.ok(instructions.includes(identity), `instructions must name ${identity}`);
    assert.ok(designated.includes(identity), `designated requirement must name ${identity}`);
  }
});
