import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";

type RunAptRetryScriptFixtureOptions = {
  commandName: "apt-get" | "bunx";
  commandOutput: string;
  commandStatus: number;
  env: Record<string, string>;
  scriptPath: string;
};

type AptRetryScriptFixtureResult = {
  attempts: number;
  output: string;
  status: number;
};

const writeExecutable = (path: string, contents: string): void => {
  writeFileSync(path, contents, { encoding: "utf8", mode: 0o755 });
  chmodSync(path, 0o755);
};

export const runAptRetryScriptFixture = ({
  commandName,
  commandOutput,
  commandStatus,
  env,
  scriptPath,
}: RunAptRetryScriptFixtureOptions): AptRetryScriptFixtureResult => {
  const fixtureDir = mkdtempSync(join(tmpdir(), "apt-retry-script-"));
  const binDir = join(fixtureDir, "bin");
  const attemptsFile = join(fixtureDir, "attempts.log");
  mkdirSync(binDir);

  try {
    writeExecutable(
      join(binDir, commandName),
      [
        "#!/usr/bin/env bash",
        'printf "attempt\\n" >> "$FIXTURE_ATTEMPTS_FILE"',
        'printf "%s\\n" "$FIXTURE_OUTPUT"',
        'exit "$FIXTURE_STATUS"',
        "",
      ].join("\n")
    );
    writeExecutable(
      join(binDir, "apt-get"),
      commandName === "apt-get"
        ? readFileSync(join(binDir, commandName), "utf8")
        : "#!/usr/bin/env bash\nexit 0\n"
    );
    writeExecutable(join(binDir, "find"), "#!/usr/bin/env bash\nexit 0\n");
    writeExecutable(
      join(binDir, "id"),
      '#!/usr/bin/env bash\n[ "$1" = "-u" ] && printf "0\\n"\n'
    );
    writeExecutable(join(binDir, "sleep"), "#!/usr/bin/env bash\nexit 0\n");

    const result = spawnSync("bash", [scriptPath], {
      encoding: "utf8",
      env: {
        ...process.env,
        ...env,
        FIXTURE_ATTEMPTS_FILE: attemptsFile,
        FIXTURE_OUTPUT: commandOutput,
        FIXTURE_STATUS: String(commandStatus),
        PATH: `${binDir}${delimiter}${process.env.PATH ?? ""}`,
        RUNNER_TEMP: fixtureDir,
      },
      maxBuffer: 1024 * 1024,
      timeout: 15_000,
    });

    if (result.error) {
      throw result.error;
    }
    if (result.status === null) {
      throw new Error(
        `fixture shell exited without a status (signal: ${result.signal ?? "unknown"})\n${result.stdout}${result.stderr}`
      );
    }

    const attempts = existsSync(attemptsFile)
      ? readFileSync(attemptsFile, "utf8").split(/\r?\n/).filter(Boolean).length
      : 0;

    return {
      attempts,
      output: `${result.stdout}${result.stderr}`,
      status: result.status,
    };
  } finally {
    rmSync(fixtureDir, { force: true, recursive: true });
  }
};
