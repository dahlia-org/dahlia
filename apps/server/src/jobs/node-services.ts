import { ChatMemoryService, createMemoryGenerator } from "../agent/context-service";
import { WorkspaceMemoryService } from "../memory/service";
import { createAudioSummaryMethod } from "../summary/audio";
import { createTranscriptSummaryMethod } from "../summary/transcript";
import { SummaryService } from "../summary/service";

import { createNodeApplicationStore } from "../auth/node-store";
import { NODE_STORAGE_OPERATION_CONCURRENCY } from "../db/client";
import { DatabricksVolumeObjectStorage } from "../storage/databricks-volume";
import { LocalObjectStorage } from "../storage/local";
import { S3ObjectStorage } from "../storage/s3";
import { createNodeSearchTokenizer } from "../search/node-tokenizer";
import { createSearchEmbedder } from "../search/embedding";
import { transformScreenshot } from "../sync/node-screenshot-transformer";
import { MeetingSyncService } from "../sync/service";
import { createImageCaptioner } from "../image-analysis/captioner";

import type { AppConfig } from "../config";
import { createOtel } from "../otel/service";

export function createNodeServices(config: AppConfig, poolMax?: number, storageConcurrency = NODE_STORAGE_OPERATION_CONCURRENCY) {
  const searchEmbedder = createSearchEmbedder(config);
  const applicationStore = createNodeApplicationStore(config, undefined, poolMax);
  let objectStorage: DatabricksVolumeObjectStorage | S3ObjectStorage | LocalObjectStorage;
  switch (config.storageBackend) {
    case "databricks":
      objectStorage = new DatabricksVolumeObjectStorage(config.databricksWorkspace!, config.storageDatabricksVolumePath!);
      break;
    case "s3":
      objectStorage = new S3ObjectStorage(config.storageS3!);
      break;
    case "local":
      objectStorage = new LocalObjectStorage(config.storageLocalPath!);
      break;
    default:
      throw new Error("R2 storage requires a Worker binding");
  }
  const searchTokenizer = createNodeSearchTokenizer();
  const captioner = createImageCaptioner(config);
  const syncService = new MeetingSyncService(applicationStore.sync, objectStorage, searchTokenizer,
    searchEmbedder, transformScreenshot,
    config.storageBackend === "databricks" ? config.storageDatabricksVolumePath : undefined,
    false, captioner?.model, storageConcurrency);
  const workspaceMemory = config.hindsight && applicationStore.memory ? new WorkspaceMemoryService(config, applicationStore.memory, syncService, applicationStore.sync) : undefined;
  const personalMemory = config.hindsight && applicationStore.personalMemory ? new WorkspaceMemoryService(config, applicationStore.personalMemory, syncService, applicationStore.sync) : undefined;
  const chatMemory = applicationStore.chatMemoryStore ? new ChatMemoryService(applicationStore.chatMemoryStore, syncService, createMemoryGenerator(config)) : undefined;
  const summaryMethods = [createTranscriptSummaryMethod(config, applicationStore.sync, syncService),
    createAudioSummaryMethod(config, applicationStore.sync, syncService)].filter((method) => method !== undefined);
  const summaryService = summaryMethods.length ? new SummaryService(applicationStore.sync, summaryMethods) : undefined;
  const otel = createOtel(config);

  return { applicationStore, searchEmbedder, objectStorage, searchTokenizer, captioner, syncService, workspaceMemory, personalMemory, chatMemory, summaryMethods, summaryService, otel };
}
