import * as core from "@actions/core";
import * as exec from "@actions/exec";
import * as path from "path";


/**
 * The main function for the action.
 *
 * @returns Resolves when the action is complete.
 */
export async function run(): Promise<void> {
  try {
    const mode: string = core.getInput("mode") || "minimal";
    const interval: string = core.getInput("interval") || "1";

    // Debug logs are only output if the `ACTIONS_STEP_DEBUG` secret is true
    core.info(
      `Starting system monitoring with mode: ${mode}, interval: ${interval} minutes`
    );

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

    // Start the monitoring script in the background
    let stdout = "";
    let stderr = "";

    const exitCode = await exec.exec(scriptPath, args, {
      listeners: {
        stdout: (data: Buffer) => {
          stdout += data.toString();
        },
        stderr: (data: Buffer) => {
          stderr += data.toString();
        },
      },
    });

    if (exitCode === 0) {
      core.info("System monitoring script started successfully");
      core.info(`Output file: ${outputFile}`);
      core.info(`Monitor mode: ${mode}`);
      core.info(`Update interval: ${interval} minutes`);

      // Set outputs for other workflow steps to use
      core.setOutput("output-file", outputFile);
      core.setOutput("monitor-mode", mode);
      core.setOutput("interval", interval);
      core.setOutput("started-at", new Date().toISOString());
    } else {
      core.setFailed(`Script execution failed with exit code: ${exitCode}`);
    }

    if (stdout) {
      core.info("Script output:");
      core.info(stdout);
    }

    if (stderr) {
      core.warning("Script stderr:");
      core.warning(stderr);
    }
  } catch (error) {
    // Fail the workflow run if an error occurs
    if (error instanceof Error) core.setFailed(error.message);
  }
}
