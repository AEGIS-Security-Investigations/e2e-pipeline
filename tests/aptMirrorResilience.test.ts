import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runAptRetryScriptFixture } from "./runAptRetryScriptFixture";

const REPO_ROOT = join(__dirname, "..");
const APT_HARDENING_DIR = join(REPO_ROOT, "actions/apt-hardening");
const APT_FAILURE_CLASSIFIER = join(APT_HARDENING_DIR, "classifyAptFailure.sh");
const PLAYWRIGHT_INSTALL_DIR = join(
  REPO_ROOT,
  "actions/playwright-install"
);

const hardenApt = readFileSync(join(APT_HARDENING_DIR, "hardenApt.sh"), "utf8");
const aptUpdate = readFileSync(join(APT_HARDENING_DIR, "aptUpdate.sh"), "utf8");
const installBrowsers = readFileSync(
  join(PLAYWRIGHT_INSTALL_DIR, "installBrowsers.sh"),
  "utf8"
);
const playwrightInstallAction = readFileSync(
  join(PLAYWRIGHT_INSTALL_DIR, "action.yml"),
  "utf8"
);
const APT_UPDATE_SCRIPT = join(APT_HARDENING_DIR, "aptUpdate.sh");
const PLAYWRIGHT_INSTALL_SCRIPT = join(
  PLAYWRIGHT_INSTALL_DIR,
  "installBrowsers.sh"
);

const classifyFailure = (
  mode: "apt" | "browser" | "playwright",
  output: string
): boolean => {
  const fixtureDir = mkdtempSync(join(tmpdir(), "apt-failure-classifier-"));
  const fixturePath = join(fixtureDir, "command.log");

  try {
    writeFileSync(fixturePath, output, "utf8");
    const result = spawnSync(
      "bash",
      [APT_FAILURE_CLASSIFIER, mode, fixturePath],
      { encoding: "utf8" }
    );

    if (result.status !== 0 && result.status !== 1) {
      throw new Error(
        `classifier exited ${result.status}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`
      );
    }

    return result.status === 0;
  } finally {
    rmSync(fixtureDir, { recursive: true, force: true });
  }
};

describe("apt-hardening and playwright-install (moved from myGuardForce, AEG-5572)", () => {
  test("AEG-5572 apt hardening skips the indexes that lag mirror syncs", () => {
    expect(hardenApt).toContain(
      'Acquire::IndexTargets::deb::DEP-11::DefaultEnabled "false"'
    );
    expect(hardenApt).toContain(
      'Acquire::IndexTargets::deb::Contents-deb::DefaultEnabled "false"'
    );
    expect(hardenApt).toContain('Acquire::Languages "none"');
  });

  test("AEG-5572 apt hardening is global so Playwright's own apt-get inherits it", () => {
    // Playwright shells out to its own `apt-get update`; only configuration in
    // /etc/apt/apt.conf.d reaches it.
    expect(hardenApt).toContain("/etc/apt/apt.conf.d/99-ci-mirror-resilience");
    expect(hardenApt).toContain('Acquire::Retries "5"');
  });

  test("AEG-5572 apt hardening is a no-op instead of a failure without root", () => {
    // The self-hosted AWS pod has no root and bakes the libraries into the
    // image (AEG-3744); hardening must not fail those jobs.
    for (const script of [hardenApt, aptUpdate]) {
      expect(script).toContain("sudo -n true");
      expect(script).toContain("exit 0");
    }
  });

  test("AEG-5572 apt-get update retries with freshly fetched lists", () => {
    expect(aptUpdate).toContain("APT_UPDATE_ATTEMPTS");
    // Retrying without clearing the cached, half-synced lists just replays the
    // same size mismatch.
    expect(aptUpdate).toContain("/var/lib/apt/lists");
    expect(aptUpdate).toContain("sleep");
    expect(aptUpdate).toContain('isTransientAptFailure "$attemptLog"');
  });

  test("AEG-5572 a deps-less fallback only proceeds when Chromium actually launches", () => {
    expect(installBrowsers).toContain("playwright screenshot");
    expect(installBrowsers).toContain("--browser=chromium");
    expect(installBrowsers).toContain("::error::Chromium could not launch");
    expect(installBrowsers).toContain(
      "Cannot verify the dependency-free fallback because Chromium was not requested"
    );
    expect(installBrowsers).toContain(
      'isTransientPlaywrightAptFailure "$logFile"'
    );
    expect(installBrowsers).toContain(
      'isRetryableInstallFailure "$status" "$attemptLog"'
    );
  });

  test("AEG-10217 skips Playwright install when cached Chromium already launches", () => {
    expect(installBrowsers).toContain("playwright-cache-check.png");
    expect(installBrowsers).toContain(
      "Playwright Chromium already launches from cache; skipping install."
    );
    expect(installBrowsers).toContain("PLAYWRIGHT_BROWSERS_PATH");
  });

  test("AEG-5572 only transient apt or mirror failures are retryable", () => {
    expect(
      classifyFailure(
        "apt",
        "File has unexpected size (46348 != 46400). Mirror sync in progress?"
      )
    ).toBe(true);
    expect(
      classifyFailure(
        "apt",
        "Temporary failure resolving 'security.ubuntu.com'"
      )
    ).toBe(true);
    expect(
      classifyFailure("apt", "E: Unable to locate package postgresql-client")
    ).toBe(false);
    expect(
      classifyFailure(
        "apt",
        "E: The repository 'https://example.invalid stable Release' does not have a Release file."
      )
    ).toBe(false);
    expect(
      classifyFailure(
        "apt",
        [
          "Temporary failure resolving security.ubuntu.com",
          "E: Unable to locate package definitely-not-real",
        ].join("\n")
      )
    ).toBe(false);
  });

  test("AEG-5572 Playwright retry requires both a transient marker and apt exit 100", () => {
    expect(
      classifyFailure(
        "playwright",
        [
          "File has unexpected size (46348 != 46400). Mirror sync in progress?",
          "Failed to install browsers",
          "Error: Installation process exited with code: 100",
        ].join("\n")
      )
    ).toBe(true);
    expect(
      classifyFailure(
        "playwright",
        [
          "Temporary failure resolving 'security.ubuntu.com'",
          "Error: Download failure, code=1",
        ].join("\n")
      )
    ).toBe(false);
    expect(
      classifyFailure(
        "playwright",
        [
          "Temporary failure resolving security.ubuntu.com",
          "E: Unable to locate package playwright-dependency",
          "Error: Installation process exited with code: 100",
        ].join("\n")
      )
    ).toBe(false);
    expect(
      classifyFailure(
        "playwright",
        "Error: Installation process exited with code: 100"
      )
    ).toBe(false);
  });

  test("AEG-5613 browser download classifier accepts Node transport errors only", () => {
    for (const transientOutput of [
      "Error: read ECONNRESET",
      "Error: connect ETIMEDOUT 192.0.2.1:443",
      "Error: getaddrinfo EAI_AGAIN cdn.playwright.dev",
      "Error: getaddrinfo ENOTFOUND cdn.playwright.dev",
      "Error: socket hang up",
      "Error: Download failed: server returned code 503",
    ]) {
      expect(classifyFailure("browser", transientOutput)).toBe(true);
    }

    expect(
      classifyFailure("browser", "Error: Invalid installation target firefoxx")
    ).toBe(false);
    expect(
      classifyFailure(
        "browser",
        [
          "Error: read ECONNRESET",
          "Error: Invalid installation target firefoxx",
        ].join("\n")
      )
    ).toBe(false);
  });

  for (const timeoutStatus of [124, 137]) {
    test(`AEG-5613 apt timeout exit ${timeoutStatus} retries the configured attempts`, () => {
      const result = runAptRetryScriptFixture({
        commandName: "apt-get",
        commandOutput: "Reading package lists...",
        commandStatus: timeoutStatus,
        env: {
          APT_UPDATE_ATTEMPTS: "2",
          APT_UPDATE_ATTEMPT_TIMEOUT: "1s",
        },
        scriptPath: APT_UPDATE_SCRIPT,
      });

      expect(result.status).toBe(timeoutStatus);
      expect(result.attempts).toBe(2);
      expect(result.output).toContain("retryable timeout");
      expect(result.output).not.toContain(
        "not retrying a real package or configuration failure"
      );
    });

    test(`AEG-5613 Playwright timeout exit ${timeoutStatus} retries the configured attempts`, () => {
      const result = runAptRetryScriptFixture({
        commandName: "bunx",
        commandOutput: "Downloading Chromium...",
        commandStatus: timeoutStatus,
        env: {
          PW_DEPS_FALLBACK: "false",
          PW_INSTALL_ATTEMPTS: "2",
          PW_INSTALL_ATTEMPT_TIMEOUT: "1s",
          PW_WITH_DEPS: "true",
        },
        scriptPath: PLAYWRIGHT_INSTALL_SCRIPT,
      });

      expect(result.status).toBe(timeoutStatus);
      expect(result.attempts).toBe(2);
      expect(result.output).not.toContain("not retrying or hiding");
    });
  }

  test("AEG-5613 dependency-free Playwright retries transient CDN failures", () => {
    const result = runAptRetryScriptFixture({
      commandName: "bunx",
      commandOutput: "Error: read ECONNRESET while downloading chromium",
      commandStatus: 1,
      env: {
        PW_INSTALL_ATTEMPTS: "2",
        PW_WITH_DEPS: "false",
      },
      scriptPath: PLAYWRIGHT_INSTALL_SCRIPT,
    });

    expect(result.status).toBe(1);
    expect(result.attempts).toBe(2);
    expect(result.output).toContain("failed after 2 attempts");
  });

  test("AEG-5613 dependency installs reject transient-looking non-apt failures", () => {
    const result = runAptRetryScriptFixture({
      commandName: "bunx",
      commandOutput: [
        "Temporary failure resolving security.ubuntu.com",
        "E: Unable to locate package playwright-dependency",
        "Error: Installation process exited with code: 100",
      ].join("\n"),
      commandStatus: 1,
      env: {
        PW_INSTALL_ATTEMPTS: "3",
        PW_WITH_DEPS: "true",
      },
      scriptPath: PLAYWRIGHT_INSTALL_SCRIPT,
    });

    expect(result.status).toBe(1);
    expect(result.attempts).toBe(1);
    expect(result.output).toContain("not retrying or hiding");
  });

  test("AEG-5613 permanent package and browser errors fail immediately", () => {
    const aptResult = runAptRetryScriptFixture({
      commandName: "apt-get",
      commandOutput: "E: Unable to locate package definitely-not-real",
      commandStatus: 100,
      env: { APT_UPDATE_ATTEMPTS: "3" },
      scriptPath: APT_UPDATE_SCRIPT,
    });
    const browserResult = runAptRetryScriptFixture({
      commandName: "bunx",
      commandOutput: "Error: Invalid installation target not-a-browser",
      commandStatus: 1,
      env: {
        PW_INSTALL_ATTEMPTS: "3",
        PW_WITH_DEPS: "false",
      },
      scriptPath: PLAYWRIGHT_INSTALL_SCRIPT,
    });

    expect(aptResult.attempts).toBe(1);
    expect(aptResult.status).toBe(100);
    expect(browserResult.attempts).toBe(1);
    expect(browserResult.status).toBe(1);
    expect(browserResult.output).toContain(
      "not retrying a real browser or configuration failure"
    );
  });

  const pr6850MissingFontsAfterFailedIndexes = [
    "Err:2 http://security.ubuntu.com/ubuntu noble-security InRelease",
    "  Connection failed [IP: 185.125.190.81 80]",
    "W: Failed to fetch http://security.ubuntu.com/ubuntu/dists/noble-security/InRelease  Connection failed [IP: 185.125.190.81 80]",
    "W: Some index files failed to download. They have been ignored, or old ones used instead.",
    "E: Unable to locate package fonts-unifont",
    "E: Unable to locate package fonts-ipafont-gothic",
    "E: Package 'fonts-freefont-ttf' has no installation candidate",
    "E: Package 'fonts-wqy-zenhei' has no installation candidate",
    "Failed to install browsers",
    "Error: Installation process exited with code: 100",
  ].join("\n");

  test("AEG-8528 missing fonts after failed indexes are a transient apt/mirror failure", () => {
    expect(classifyFailure("apt", pr6850MissingFontsAfterFailedIndexes)).toBe(
      true
    );
    expect(
      classifyFailure("playwright", pr6850MissingFontsAfterFailedIndexes)
    ).toBe(true);
  });

  test("AEG-8528 genuine missing package without a failed index fetch stays permanent", () => {
    expect(
      classifyFailure(
        "playwright",
        [
          "Temporary failure resolving security.ubuntu.com",
          "E: Unable to locate package playwright-dependency",
          "Error: Installation process exited with code: 100",
        ].join("\n")
      )
    ).toBe(false);
    expect(
      classifyFailure("apt", "E: Unable to locate package fonts-unifont")
    ).toBe(false);
    expect(
      classifyFailure(
        "apt",
        "E: Package 'fonts-freefont-ttf' has no installation candidate"
      )
    ).toBe(false);
  });

  test("AEG-8528 unsigned or missing Release file stays permanent even with failed indexes", () => {
    expect(
      classifyFailure(
        "apt",
        [
          "W: Some index files failed to download. They have been ignored, or old ones used instead.",
          "E: The repository 'https://example.invalid stable Release' does not have a Release file.",
        ].join("\n")
      )
    ).toBe(false);
    expect(
      classifyFailure(
        "apt",
        [
          "W: Some index files failed to download. They have been ignored, or old ones used instead.",
          "E: The repository 'https://example.invalid stable Release' is not signed.",
        ].join("\n")
      )
    ).toBe(false);
  });

  test("AEG-8528 Playwright retries and can fall through when fonts are missing because indexes failed", () => {
    const result = runAptRetryScriptFixture({
      commandName: "bunx",
      commandOutput: pr6850MissingFontsAfterFailedIndexes,
      commandStatus: 100,
      env: {
        PW_DEPS_FALLBACK: "false",
        PW_INSTALL_ATTEMPTS: "2",
        PW_WITH_DEPS: "true",
      },
      scriptPath: PLAYWRIGHT_INSTALL_SCRIPT,
    });

    expect(result.status).toBe(100);
    expect(result.attempts).toBe(2);
    expect(result.output).not.toContain("not retrying or hiding");
  });

  test("AEG-8528 Playwright --with-deps attempts default to 90s", () => {
    expect(playwrightInstallAction).toContain('default: "90s"');
    expect(installBrowsers).toContain("PW_INSTALL_ATTEMPT_TIMEOUT:-90s");
  });

  test("AEG-10216 Playwright browser-download fallback defaults to 3m", () => {
    expect(playwrightInstallAction).toContain(
      "PW_BROWSER_DOWNLOAD_TIMEOUT: ${{ inputs.browser-download-timeout }}"
    );
    expect(playwrightInstallAction).toContain('default: "3m"');
    expect(installBrowsers).toContain("PW_BROWSER_DOWNLOAD_TIMEOUT:-3m");
    expect(installBrowsers).toContain(
      'ATTEMPT_TIMEOUT="$BROWSER_DOWNLOAD_TIMEOUT"'
    );
  });
});
