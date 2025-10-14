import * as core from "@actions/core";
import * as exec from "@actions/exec";
import * as path from "path";
import { spawn } from "child_process";
import * as fs from "fs";
/**
 * The main function for the action.
 *
 * @returns Resolves when the action is complete.
 */
export async function run() {
    try {
        const mode = core.getInput("mode") || "minimal";
        const interval = core.getInput("interval") || "1";
        // Debug logs are only output if the `ACTIONS_STEP_DEBUG` secret is true
        core.info(`Starting system monitoring with mode: ${mode}, interval: ${interval} minutes`);
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
        ];
        core.info(`Executing: ${scriptPath} ${args.join(" ")}`);
        // Start the monitoring script in the background (non-blocking)
        const logFile = `${process.env.RUNNER_TEMP}/ghametrics_monitor.log`;
        const pidFile = `${process.env.RUNNER_TEMP}/ghametrics_monitor.pid`;
        const logStream = fs.createWriteStream(logFile, { flags: "a" });
        const child = spawn(scriptPath, args, {
            detached: true,
            stdio: ["ignore", logStream, logStream],
        });
        // Save the PID to a file for later reference
        if (child.pid) {
            fs.writeFileSync(pidFile, child.pid.toString());
            core.info(`Process handle saved to: ${pidFile}`);
        }
        // Unref the child process so it doesn't keep the parent alive
        child.unref();
        core.info(`System monitoring script started in background (PID: ${child.pid})`);
        core.info(`Output file: ${outputFile}`);
        core.info(`Log file: ${logFile}`);
        core.info(`Monitor mode: ${mode}`);
        core.info(`Update interval: ${interval} minutes`);
        // Set outputs for other workflow steps to use
        core.setOutput("output-file", outputFile);
        core.setOutput("log-file", logFile);
        core.setOutput("pid-file", pidFile);
        core.setOutput("monitor-mode", mode);
        core.setOutput("interval", interval);
        core.setOutput("started-at", new Date().toISOString());
        core.setOutput("pid", child.pid?.toString() || "unknown");
        core.info("Action completed - monitoring continues in background");
        core.info(`To stop the monitor later, use: kill $(cat ${pidFile})`);
    }
    catch (error) {
        if (error instanceof Error)
            core.setFailed(error.message);
    }
}
//# sourceMappingURL=main.js.map