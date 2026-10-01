import { availableParallelism, totalmem } from "node:os";
import { constrainedMemory } from "node:process";
import type { JobConfig } from "./model";

export function jobResources(config: Pick<JobConfig, "workers" | "concurrency">,
  cpu = availableParallelism(), memory = Math.min(totalmem(), constrainedMemory() || Infinity)) {
  // ponytail: 512 MiB per slot is a sizing heuristic; override after measuring the deployment's jobs.
  const slotBudget = Math.max(1, Math.floor(memory * 0.75 / (512 * 1024 ** 2)));
  const slotsPerWorker = config.concurrency === "auto" ? 4 : config.concurrency;
  const workers = config.workers === "auto" ? Math.max(1, Math.min(cpu,
    Math.floor(slotBudget / slotsPerWorker))) : config.workers;
  const concurrency = config.concurrency === "auto" ? Math.max(1, Math.min(8, Math.floor(slotBudget / workers))) : config.concurrency;
  return { workers, concurrency, slots: workers * concurrency, poolMax: 2 * concurrency + 2 };
}
