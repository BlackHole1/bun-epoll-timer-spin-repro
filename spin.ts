// Measures how much CPU a self-rescheduling timer chain costs on the current runtime.
//
// Modes:
//   timer1   setTimeout(fn, 1) that re-arms itself inside its own callback
//   timer10  the same chain with a 10 ms delay
//   kafkajs  the real kafkajs 2.2.4 RequestQueue: scheduleCheckPendingRequests() re-arms a
//            timer unconditionally with a negative delay, which the runtime clamps to 1 ms
//
// Usage: bun spin.ts [mode] [seconds]

const mode = process.argv[2] ?? "timer1";
const seconds = Number(process.argv[3] ?? 5);
let iterations = 0;

if (mode === "kafkajs") {
  const { createRequire } = await import("node:module");
  const requireModule = createRequire(import.meta.url);
  const RequestQueue = requireModule("kafkajs/src/network/requestQueue/index.js");
  const noop = () => {};
  const queue = new RequestQueue({
    maxInFlightRequests: null,
    requestTimeout: 30_000,
    enforceRequestTimeout: false,
    clientId: "repro",
    broker: "broker:9092",
    logger: { debug: noop, info: noop, warn: noop, error: noop },
  });
  const original = queue.checkPendingRequests.bind(queue);
  queue.checkPendingRequests = () => {
    iterations++;
    original();
  };
  // This is what fulfillRequest() does once the first response arrives on a connection.
  queue.checkPendingRequests();
} else if (mode === "timer1" || mode === "timer10") {
  const delay = mode === "timer10" ? 10 : 1;
  const tick = () => {
    iterations++;
    setTimeout(tick, delay);
  };
  tick();
} else {
  console.error(`unknown mode: ${mode}`);
  process.exit(2);
}

const cpuStart = process.cpuUsage();
const wallStart = performance.now();

setTimeout(() => {
  const cpu = process.cpuUsage(cpuStart);
  const wall = (performance.now() - wallStart) / 1000;
  const runtime = typeof Bun !== "undefined" ? `bun ${Bun.version}` : `node ${process.version}`;
  console.log(
    JSON.stringify({
      runtime,
      mode,
      iterationsPerSecond: Math.round(iterations / wall),
      userCpuPercent: Number((cpu.user / 1e4 / wall).toFixed(1)),
      systemCpuPercent: Number((cpu.system / 1e4 / wall).toFixed(1)),
    }),
  );
  process.exit(0);
}, seconds * 1000);
