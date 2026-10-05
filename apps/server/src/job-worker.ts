import { loadConfig } from "./config";
import { loadJobConfig } from "./jobs/model";
import { jobResources } from "./jobs/resources";
import { createNodeServices } from "./jobs/node-services";
import { createJobExecutor } from "./jobs/execute";
import { JobRunner } from "./jobs/node-runner";
import { setLogSink } from "./otel/log";

const config = loadConfig(process.env);
const resources = jobResources(config.jobs ?? loadJobConfig({}));
const s = createNodeServices(config, resources.poolMax, resources.concurrency);
setLogSink(s.otel);
const runner = new JobRunner(createJobExecutor({ queue: s.applicationStore.jobs, summaryJobs: s.applicationStore.summaryJobs,
  methods: s.summaryMethods, imageAnalysis: s.applicationStore.imageAnalysis, captioner: s.captioner,
  searchIndex: s.applicationStore.searchIndex, embedder: s.searchEmbedder, sync: s.syncService, syncStore: s.applicationStore.sync,
  memory: s.workspaceMemory, personalMemory: s.personalMemory, chatMemory: s.chatMemory }), resources.concurrency);
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  await runner.stop();
  await s.otel?.shutdown();
  await s.applicationStore.close?.();
  process.disconnect?.();
}
process.once("SIGTERM", () => { void stop(); });
process.once("SIGINT", () => { void stop(); });
process.once("disconnect", () => { void stop(); });
await s.applicationStore.jobs.scheduleMaintenance();
runner.start();
process.send?.("ready");
