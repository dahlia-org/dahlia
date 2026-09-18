const port = process.env.DATABRICKS_APP_PORT ?? process.env.PORT ?? "3000";
const deadline = Date.now() + 30_000;

while (true) {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/healthz`, {
      signal: AbortSignal.timeout(1_000),
    });
    await response.body?.cancel();
    if (response.ok) break;
  } catch {
    // The API is still starting.
  }
  if (Date.now() >= deadline) throw new Error(`API did not become ready on port ${port}`);
  await new Promise((resolve) => setTimeout(resolve, 100));
}
