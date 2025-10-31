import * as core from "@actions/core";
import * as exec from "@actions/exec";
import * as path from "path";
import { spawn } from "child_process";
import * as fs from "fs";
import { randomUUID } from "crypto";

/**
 * The main function for the action.
 *
 * @returns Resolves when the action is complete.
 */
export async function run(): Promise<void> {
  try {
    const mode: string = core.getInput("mode") || "minimal";
    const interval: string = core.getInput("interval") || "1";

    // Generate a unique UUID for this job
    const jobUuid: string = randomUUID();

    // Debug logs are only output if the `ACTIONS_STEP_DEBUG` secret is true
    core.info(
      `Starting system monitoring with mode: ${mode}, interval: ${interval} minutes`
    );
    core.info(`Job UUID: ${jobUuid}`);

    // Get the path to the linux.sh script
    const scriptPath = path.join(__dirname, "scripts", "linux.sh");
    const outputFile = `${process.env.RUNNER_TEMP}/ghametrics.json`;

    // Make the script executable
    await exec.exec("chmod", ["+x", scriptPath]);

    // Prepare the command arguments
    const args = [
      "--mode",
      mode,
      "--interval",
      interval,
      "--output",
      outputFile,
      "--user",
      process.env.GITHUB_ACTOR || "github-action",
      "--repos",
      process.env.GITHUB_REPOSITORY || "",
      "--job-uuid",
      jobUuid,
    ];

    core.info(`Executing: ${scriptPath} ${args.join(" ")}`);

    // Start the monitoring script in the background (non-blocking)
    const logFile = `${process.env.RUNNER_TEMP}/ghametrics_monitor.log`;
    const pidFile = `${process.env.RUNNER_TEMP}/ghametrics_monitor.pid`;

    // Open file descriptors for stdout/stderr redirection
    const logFd = fs.openSync(logFile, "a");

    const child = spawn(scriptPath, args, {
      detached: true,
      stdio: ["ignore", logFd, logFd],
    });

    // Close the file descriptor in the parent process
    fs.closeSync(logFd);

    // Save the PID to a file for later reference
    if (child.pid) {
      fs.writeFileSync(pidFile, child.pid.toString());
      core.info(`Process handle saved to: ${pidFile}`);
      
      // Save state for post action cleanup
      core.saveState("monitorPid", child.pid.toString());
      core.saveState("outputFile", outputFile);
      core.saveState("logFile", logFile);
    }

    // Unref the child process so it doesn't keep the parent alive
    child.unref();

    core.info(
      `System monitoring script started in background (PID: ${child.pid})`
    );
    core.info(`Output file: ${outputFile}`);
    core.info(`Log file: ${logFile}`);
    core.info(`Monitor mode: ${mode}`);
    core.info(`Update interval: ${interval} minutes`);

    core.info("Action completed - monitoring continues in background");
  } catch (error) {
    if (error instanceof Error) core.setFailed(error.message);
  }
}
