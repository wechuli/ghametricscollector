import * as core from "@actions/core";
import { DefaultArtifactClient } from "@actions/artifact";
import * as fs from "fs";

/**
 * The post function for the action.
 * This runs after the main action and all subsequent steps complete.
 */
export async function post(): Promise<void> {
  try {
    // Retrieve the saved state
    const monitorPid = core.getState("monitorPid");
    const outputFile = core.getState("outputFile");
    const logFile = core.getState("logFile");

    if (!monitorPid) {
      core.info("No monitoring process to clean up");
      return;
    }

    core.info(`Stopping monitoring process (PID: ${monitorPid})`);

    // Kill the monitoring process
    try {
      process.kill(parseInt(monitorPid, 10), "SIGTERM");
      core.info("Monitoring process stopped successfully");

      // Wait a bit for the process to write final data
      await new Promise((resolve) => setTimeout(resolve, 2000));
    } catch (error) {
      if (error instanceof Error) {
        // Process might have already exited
        core.warning(`Could not stop process: ${error.message}`);
      }
    }

    // Upload artifacts
    const filesToUpload: string[] = [];

    if (outputFile && fs.existsSync(outputFile)) {
      core.info(`Metrics collected in: ${outputFile}`);
      filesToUpload.push(outputFile);
    }

    if (logFile && fs.existsSync(logFile)) {
      core.info(`Monitor logs available at: ${logFile}`);
      filesToUpload.push(logFile);
    }

    if (filesToUpload.length > 0) {
      const artifactName = "system-metrics";
      core.info(
        `Uploading ${filesToUpload.length} file(s) as artifact: ${artifactName}`
      );

      const artifactClient = new DefaultArtifactClient();
      const uploadResult = await artifactClient.uploadArtifact(
        artifactName,
        filesToUpload,
        process.env.RUNNER_TEMP || "/tmp"
      );

      core.info(`Artifact uploaded successfully. ID: ${uploadResult.id}`);
      core.info(`Size: ${uploadResult.size} bytes`);
    } else {
      core.warning("No metrics files found to upload");
    }
  } catch (error) {
    if (error instanceof Error) {
      core.warning(`Post action cleanup failed: ${error.message}`);
    }
  }
}

post();
