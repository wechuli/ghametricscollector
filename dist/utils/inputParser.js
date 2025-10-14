import * as core from "@actions/core";
export function parseInputs() {
    let mode = core.getInput("mode") || "minimal";
    let interval = parseInt(core.getInput("interval")) || 1;
    if (!["minimal", "extended", "full"].includes(mode)) {
        mode = "minimal";
    }
    if (isNaN(interval) || interval <= 0) {
        interval = 1;
    }
    return { mode, interval };
}
//# sourceMappingURL=inputParser.js.map