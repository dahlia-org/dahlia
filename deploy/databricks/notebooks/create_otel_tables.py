# Databricks notebook source
# MAGIC %md
# MAGIC Creates `<catalog>.<ops_schema>.<table_prefix>_otel_spans`, `_otel_logs` and `_otel_metrics` through MLflow's
# MAGIC Unity Catalog trace location and links them to the bundle's experiment, whose Traces tab reads the spans table.
# MAGIC Databricks owns the table definitions. Dahlia Server writes to the tables through Zerobus, not the MLflow OTLP endpoint.

# COMMAND ----------

# MAGIC %pip install --quiet "mlflow[databricks]>=3.14"

# COMMAND ----------

dbutils.library.restartPython()

# COMMAND ----------

import os
from uuid import uuid4

import mlflow
from databricks.sdk import WorkspaceClient
from databricks.sdk.service.sql import CreateWarehouseRequestWarehouseType, State
from mlflow.entities.trace_location import UnityCatalog

catalog, schema, prefix = (dbutils.widgets.get(name) for name in ("catalog", "ops_schema", "table_prefix"))
workspace = WorkspaceClient()
temporary = None
# Prefer a running, then a serverless warehouse visible to the run-as principal; MLflow starts a stopped one.
candidates = [item for item in workspace.warehouses.list() if item.state not in (State.DELETED, State.DELETING)]
candidates.sort(key=lambda item: (item.state != State.RUNNING, not item.enable_serverless_compute))
if candidates:
    warehouse = candidates[0].id
else:
    temporary = workspace.warehouses.create_and_wait(
        name=f"dahlia-otel-tables-{uuid4().hex[:8]}", cluster_size="2X-Small", min_num_clusters=1, max_num_clusters=1,
        auto_stop_mins=10, enable_serverless_compute=True, warehouse_type=CreateWarehouseRequestWarehouseType.PRO,
    )
    warehouse = temporary.id
print(f"Using SQL warehouse {warehouse}{' (temporary)' if temporary else ''}")
os.environ["MLFLOW_TRACING_SQL_WAREHOUSE_ID"] = warehouse

try:
    mlflow.set_tracking_uri("databricks")
    # Idempotent for the same location; MLflow rejects relinking the experiment to a different one.
    experiment = mlflow.set_experiment(
        experiment_id=dbutils.widgets.get("experiment_id"),
        trace_location=UnityCatalog(catalog_name=catalog, schema_name=schema, table_prefix=prefix),
    )
    print(experiment.trace_location)
finally:
    if temporary:
        workspace.warehouses.delete(temporary.id)

for signal in ("spans", "logs", "metrics"):
    table = f"`{catalog}`.`{schema}`.`{prefix}_otel_{signal}`"
    if not spark.catalog.tableExists(table):
        raise RuntimeError(f"MLflow did not create {table}")
