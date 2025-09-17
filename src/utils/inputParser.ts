import * as core from "@actions/core";

interface ActionInputs {
  mode: string;
  interval: number;
}

export function parseInputs(): ActionInputs {
  let mode: string = core.getInput("mode") || "minimal";
  let interval: number = parseInt(core.getInput("interval")) || 1;

  if (!["minimal", "extended", "full"].includes(mode)) {
    mode = "minimal";
  }

  if (isNaN(interval) || interval <= 0) {
    interval = 1;
  }

  return { mode, interval };
}
