import { expect, it } from "vitest";
import { Pool } from "pg";
import { PostgresSyncEvents } from "../src/sync/events-node";
import { uuidV7 } from "@dahlia-ai/ui/model/id";

it.runIf(process.env.TEST_DATABASE_URL)("wakes a separate Node instance through PostgreSQL without waiting for its fallback", async () => {
  const pools = [new Pool({ connectionString: process.env.TEST_DATABASE_URL }), new Pool({ connectionString: process.env.TEST_DATABASE_URL })];
  const writer = new PostgresSyncEvents(pools[0]!), receiver = new PostgresSyncEvents(pools[1]!);
  const key = `${uuidV7()}/${uuidV7()}`, watch = receiver.watch(key, new AbortController().signal);
  try {
    await expect.poll(() => receiver.pollInterval).toBe(5_000);
    watch.consume();
    const arrived = watch.wait();
    writer.publish(key);
    // Actual DB notification, not the 5-second fallback or a shared JS event bus.
    await Promise.race([arrived, new Promise((_, reject) => {
      const timer = setTimeout(() => reject(new Error("notification deadline exceeded")), 1_000);
      void arrived.finally(() => clearTimeout(timer));
    })]);
  } finally { watch.close(); await writer.close(); await receiver.close(); await Promise.all(pools.map((pool) => pool.end())); }
});
