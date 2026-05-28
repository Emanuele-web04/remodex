// FILE: windows-scheduled-task.test.js
// Purpose: Verifies Windows per-user Task Scheduler bridge lifecycle helpers without creating real tasks.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/windows-scheduled-task, ../src/daemon-state

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  buildWindowsBridgeRunnerCmd,
  buildWindowsScheduledTaskXml,
  getWindowsBridgeServiceStatus,
  parseCsvRecords,
  resetWindowsBridgePairing,
  runWindowsBridgeService,
  startWindowsBridgeService,
  stopWindowsBridgeService,
  terminateRecordedBridgeProcess,
  writeWindowsBridgeRunnerCmd,
  TASK_NAME,
} = require("../src/windows-scheduled-task");
const {
  readBridgeStatus,
  readDaemonConfig,
  readPairingSession,
  resolveBridgeStatusPath,
  resolvePairingSessionPath,
  writeBridgeStatus,
  writeDaemonConfig,
  writePairingSession,
} = require("../src/daemon-state");

test("buildWindowsScheduledTaskXml configures a per-user logon task with no execution limit", () => {
  const xml = buildWindowsScheduledTaskXml({
    actionCommand: "C:\\Windows\\System32\\cmd.exe",
    actionArguments: "/d /c \"\"C:\\Users\\Dom Test\\.remodex\\windows-bridge-runner.cmd\"\"",
    workingDirectory: "C:\\Users\\Dom Test\\.remodex",
  });

  assert.match(xml, /<URI>\\Remodex\\Bridge<\/URI>/);
  assert.match(xml, /<LogonTrigger>\s*<Enabled>true<\/Enabled>\s*<\/LogonTrigger>/);
  assert.match(xml, /<LogonType>InteractiveToken<\/LogonType>/);
  assert.match(xml, /<MultipleInstancesPolicy>IgnoreNew<\/MultipleInstancesPolicy>/);
  assert.match(xml, /<StartWhenAvailable>true<\/StartWhenAvailable>/);
  assert.match(xml, /<ExecutionTimeLimit>PT0S<\/ExecutionTimeLimit>/);
  assert.match(xml, /<RestartOnFailure>/);
  assert.match(xml, /C:\\Users\\Dom Test\\.remodex\\windows-bridge-runner.cmd/);
});

test("buildWindowsBridgeRunnerCmd quotes paths with spaces and preserves user profile env", () => {
  const runner = buildWindowsBridgeRunnerCmd({
    env: {
      USERPROFILE: "C:\\Users\\Dom Test",
      APPDATA: "C:\\Users\\Dom Test\\AppData\\Roaming",
      LOCALAPPDATA: "C:\\Users\\Dom Test\\AppData\\Local",
      PATH: "C:\\Program Files\\nodejs",
      ComSpec: "C:\\Windows\\System32\\cmd.exe",
      CODEX_HOME: "C:\\Users\\Dom Test\\.codex",
      REMODEX_DEVICE_STATE_DIR: "C:\\Users\\Dom Test\\.remodex",
    },
    nodePath: "C:\\Program Files\\nodejs\\node.exe",
    cliPath: "C:\\Users\\Dom Test\\AppData\\Roaming\\npm\\node_modules\\remodex\\bin\\remodex.js",
    stdoutLogPath: "C:\\Users\\Dom Test\\.remodex\\logs\\bridge.stdout.log",
    stderrLogPath: "C:\\Users\\Dom Test\\.remodex\\logs\\bridge.stderr.log",
  });

  assert.match(runner, /set "USERPROFILE=C:\\Users\\Dom Test"/);
  assert.match(runner, /set "CODEX_HOME=C:\\Users\\Dom Test\\.codex"/);
  assert.match(runner, /"C:\\Program Files\\nodejs\\node\.exe" "C:\\Users\\Dom Test\\AppData\\Roaming\\npm\\node_modules\\remodex\\bin\\remodex\.js" run-service/);
  assert.match(runner, />> "C:\\Users\\Dom Test\\.remodex\\logs\\bridge\.stdout\.log" 2>> "C:\\Users\\Dom Test\\.remodex\\logs\\bridge\.stderr\.log"/);
});

test("writeWindowsBridgeRunnerCmd writes the generated runner inside the remodex state dir", () => {
  withTempDaemonEnv(({ env, rootDir }) => {
    const runnerPath = writeWindowsBridgeRunnerCmd({
      env,
      nodePath: "C:\\Program Files\\nodejs\\node.exe",
      cliPath: "C:\\Program Files\\remodex\\bin\\remodex.js",
    });

    assert.equal(runnerPath, path.join(rootDir, "windows-bridge-runner.cmd"));
    assert.equal(fs.existsSync(runnerPath), true);
    assert.match(fs.readFileSync(runnerPath, "utf8"), /run-service/);
  });
});

test("startWindowsBridgeService writes config, clears stale state, registers the task, and waits for fresh pairing", async () => {
  await withTempDaemonEnv(async ({ env }) => {
    writePairingSession({ sessionId: "stale-session" }, { now: () => 1_600_000_000_000 });
    writeBridgeStatus({ state: "stale", connectionStatus: "connected" });
    const calls = [];
    const execFileSyncImpl = (command, args) => {
      calls.push([command, args]);
      if (command === "schtasks" && args[0] === "/run") {
        writePairingSession({ sessionId: "fresh-session" }, { env });
      }
      return "";
    };

    const result = await startWindowsBridgeService({
      env,
      platform: "win32",
      execFileSyncImpl,
      nodePath: "C:\\Program Files\\nodejs\\node.exe",
      cliPath: "C:\\Program Files\\remodex\\bin\\remodex.js",
      waitForPairing: true,
      pairingTimeoutMs: 100,
      pairingPollIntervalMs: 1,
    });

    assert.equal(readDaemonConfig({ env }).relayUrl, "ws://127.0.0.1:9000/relay");
    assert.equal(readPairingSession({ env })?.pairingPayload?.sessionId, "fresh-session");
    assert.equal(readBridgeStatus({ env }), null);
    assert.equal(result.taskName, TASK_NAME);
    assert.deepEqual(calls.map((call) => call[1][0]), ["/create", "/run"]);
  });
});

test("runWindowsBridgeService records a clean error state when daemon config is missing", () => {
  withTempDaemonEnv(({ env }) => {
    runWindowsBridgeService({
      env,
      platform: "win32",
    });

    assert.equal(readPairingSession({ env }), null);
    assert.equal(readBridgeStatus({ env })?.connectionStatus, "error");
    assert.equal(readBridgeStatus({ env })?.lastError, "No relay URL configured for the Windows bridge service.");
  });
});

test("stopWindowsBridgeService ends the task and clears transient runtime files", () => {
  withTempDaemonEnv(({ env }) => {
    writePairingSession({ sessionId: "session-stop" }, { env });
    writeBridgeStatus({ state: "running", connectionStatus: "connected", pid: 4321 }, { env });
    const calls = [];
    const execFileSyncImpl = (command, args) => {
      calls.push([command, args]);
      if (command === "schtasks" && args[0] === "/query") {
        return `"TaskName","Status","Last Run Time","Last Result","Next Run Time"\n"${TASK_NAME}","Running","N/A","0","N/A"\n`;
      }
      if (command === "powershell.exe") {
        return "{\"ProcessId\":4321,\"CommandLine\":\"node.exe other-tool.js\"}";
      }
      return "";
    };

    stopWindowsBridgeService({
      env,
      platform: "win32",
      execFileSyncImpl,
      processImpl: { pid: 9999 },
    });

    assert.equal(readPairingSession({ env }), null);
    assert.equal(readBridgeStatus({ env }), null);
    assert.equal(calls.some(([, args]) => args[0] === "/end"), true);
    assert.equal(calls.some(([command]) => command === "taskkill"), false);
  });
});

test("terminateRecordedBridgeProcess only kills recorded Remodex run-service processes", () => {
  const calls = [];
  const execFileSyncImpl = (command, args) => {
    calls.push([command, args]);
    if (command === "powershell.exe") {
      return "{\"ProcessId\":2468,\"CommandLine\":\"node.exe C:\\\\Users\\\\Dom Test\\\\remodex\\\\bin\\\\remodex.js run-service\"}";
    }
    return "";
  };

  assert.equal(terminateRecordedBridgeProcess(
    { bridgeStatus: { pid: 2468 } },
    { execFileSyncImpl, processImpl: { pid: 9999 } }
  ), true);
  assert.deepEqual(calls.at(-1), ["taskkill", ["/pid", "2468", "/t", "/f"]]);
});

test("getWindowsBridgeServiceStatus combines task info, daemon state, pairing, and logs", () => {
  withTempDaemonEnv(({ env, rootDir }) => {
    writeDaemonConfig({ relayUrl: "ws://127.0.0.1:9000/relay", keepMacAwakeEnabled: false }, { env });
    writeBridgeStatus({ state: "running", connectionStatus: "connected", pid: 1357 }, { env });
    writePairingSession({ sessionId: "session-status" }, { env });
    const execFileSyncImpl = () => `"TaskName","Status","Last Run Time","Last Result","Next Run Time"\n"${TASK_NAME}","Ready","5/28/2026 10:00:00 AM","0","N/A"\n`;

    const status = getWindowsBridgeServiceStatus({
      env,
      execFileSyncImpl,
    });

    assert.equal(status.installed, true);
    assert.equal(status.taskStatus, "Ready");
    assert.equal(status.pid, 1357);
    assert.equal(status.daemonConfig.relayUrl, "ws://127.0.0.1:9000/relay");
    assert.equal(status.pairingSession.pairingPayload.sessionId, "session-status");
    assert.equal(status.stdoutLogPath, path.join(rootDir, "logs", "bridge.stdout.log"));
  });
});

test("resetWindowsBridgePairing stops the task before clearing trust state", () => {
  withTempDaemonEnv(({ env, rootDir }) => {
    fs.writeFileSync(path.join(rootDir, "device-state.json"), JSON.stringify({
      macDeviceId: "mac-1",
      macIdentityPublicKey: "pub",
      macIdentityPrivateKey: "priv",
      trustedPhones: { "phone-1": "phone-public-key" },
    }));
    writePairingSession({ sessionId: "session-reset" }, { env });
    writeBridgeStatus({ state: "running", connectionStatus: "connected", pid: 8642 }, { env });
    const calls = [];
    const execFileSyncImpl = (command, args) => {
      calls.push([command, args]);
      if (command === "schtasks" && args[0] === "/query") {
        return `"TaskName","Status","Last Run Time","Last Result","Next Run Time"\n"${TASK_NAME}","Running","N/A","0","N/A"\n`;
      }
      if (command === "powershell.exe") {
        return "{\"ProcessId\":8642,\"CommandLine\":\"node.exe C:\\\\remodex\\\\bin\\\\remodex.js run-service\"}";
      }
      return "";
    };

    resetWindowsBridgePairing({
      env,
      platform: "win32",
      execFileSyncImpl,
      processImpl: { pid: 9999 },
    });

    const deviceState = JSON.parse(fs.readFileSync(path.join(rootDir, "device-state.json"), "utf8"));
    assert.deepEqual(deviceState.trustedPhones, {});
    assert.equal(calls.findIndex(([, args]) => args[0] === "/end") < calls.findIndex(([command]) => command === "taskkill"), true);
    assert.equal(fs.existsSync(resolvePairingSessionPath({ env })), false);
    assert.equal(fs.existsSync(resolveBridgeStatusPath({ env })), false);
  });
});

test("parseCsvRecords handles quoted schtasks output", () => {
  assert.deepEqual(
    parseCsvRecords(`"TaskName","Status","Last Result"\n"${TASK_NAME}","Ready","0"\n`),
    [{ TaskName: TASK_NAME, Status: "Ready", "Last Result": "0" }]
  );
});

function withTempDaemonEnv(run) {
  const previousDir = process.env.REMODEX_DEVICE_STATE_DIR;
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-windows-task-"));
  process.env.REMODEX_DEVICE_STATE_DIR = rootDir;
  const env = {
    ...process.env,
    REMODEX_DEVICE_STATE_DIR: rootDir,
    REMODEX_RELAY: "ws://127.0.0.1:9000/relay",
    USERPROFILE: "C:\\Users\\Dom Test",
    HOME: "",
    APPDATA: "C:\\Users\\Dom Test\\AppData\\Roaming",
    LOCALAPPDATA: "C:\\Users\\Dom Test\\AppData\\Local",
    PATH: "C:\\Program Files\\nodejs",
    ComSpec: "C:\\Windows\\System32\\cmd.exe",
    CODEX_HOME: "C:\\Users\\Dom Test\\.codex",
  };

  const cleanup = () => {
    if (previousDir === undefined) {
      delete process.env.REMODEX_DEVICE_STATE_DIR;
    } else {
      process.env.REMODEX_DEVICE_STATE_DIR = previousDir;
    }
    fs.rmSync(rootDir, { recursive: true, force: true });
  };

  try {
    const result = run({ env, rootDir });
    if (result && typeof result.then === "function") {
      return result.finally(cleanup);
    }
    cleanup();
    return result;
  } catch (error) {
    cleanup();
    throw error;
  }
}
