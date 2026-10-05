import { fork, type ChildProcess } from "node:child_process";
import type { jobResources } from "./resources";
import { log } from "../otel/log";

export class JobPool {
  private readonly children: ChildProcess[] = [];
  private stopping = false;
  constructor(private readonly entry: URL, private readonly resources: ReturnType<typeof jobResources>, private readonly failed: () => void) {}
  async start() {
    log("info", "job_pool_starting", { ...this.resources, totalPoolMax: this.resources.workers * this.resources.poolMax });
    try {
      await Promise.all(Array.from({ length: this.resources.workers }, () => new Promise<void>((resolve, reject) => {
        const child = fork(this.entry, [], { env: { ...process.env, DAHLIA_JOB_CONCURRENCY: String(this.resources.concurrency) } });
        this.children.push(child);
        let ready = false;
        const timeout = setTimeout(() => reject(new Error("job_worker_start_timeout")), 30_000);
        child.on("message", (message) => { if (message === "ready") { ready = true; clearTimeout(timeout); resolve(); } });
        child.once("error", (error) => { clearTimeout(timeout); reject(error); });
        child.once("exit", () => {
          clearTimeout(timeout);
          if (!ready) reject(new Error("job_worker_start_failed"));
          if (ready && !this.stopping) this.failed();
        });
      })));
    } catch (error) { await this.stop(); throw error; }
  }
  async stop() {
    this.stopping = true;
    await Promise.all(this.children.map((child) => new Promise<void>((resolve) => {
      if (child.exitCode !== null || child.signalCode !== null) { resolve(); return; }
      const deadline = setTimeout(() => child.kill("SIGKILL"), 30_000);
      child.once("exit", () => { clearTimeout(deadline); resolve(); });
      child.kill("SIGTERM");
    })));
  }
}
