/**
 * Host shim for `@kit.PerformanceAnalysisKit` (hilog).
 * Logs are captured so tests can assert that no secret is ever logged.
 */
export const capturedLogs = [];

function record(level, args) {
  capturedLogs.push({ level, args: args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))) });
}

export const hilog = {
  isLoggable: () => false,
  debug: (...a) => record('debug', a),
  info: (...a) => record('info', a),
  warn: (...a) => record('warn', a),
  error: (...a) => record('error', a),
  fatal: (...a) => record('fatal', a),
  LogLevel: { DEBUG: 3, INFO: 4, WARN: 5, ERROR: 6, FATAL: 7 },
  Domain: { USER: 0x0000 },
};
export default { hilog, capturedLogs };
