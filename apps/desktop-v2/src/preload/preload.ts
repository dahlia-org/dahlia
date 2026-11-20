// The renderer's only way into the main process: these operations, each validated there.
import { contextBridge, ipcRenderer } from "electron";
import type { DahliaAPI } from "../shared/types.js";

const invoke = (channel: string, ...args: unknown[]) => ipcRenderer.invoke(channel, ...args);

const api: DahliaAPI = {
  auth: {
    state: () => invoke("auth:state"),
    signIn: (workspace) => invoke("auth:signIn", workspace),
    cancelSignIn: () => invoke("auth:cancelSignIn"),
    signOut: () => invoke("auth:signOut"),
  },
  meetings: {
    list: () => invoke("meetings:list"),
    get: (id) => invoke("meetings:get", id),
    create: () => invoke("meetings:create"),
    rename: (id, name) => invoke("meetings:rename", id, name),
    delete: (id) => invoke("meetings:delete", id),
  },
  recording: {
    state: () => invoke("recording:state"),
    start: (meetingId) => invoke("recording:start", meetingId),
    append: (recordingId, source, chunk) => ipcRenderer.send("recording:append", recordingId, source, chunk),
    stop: (recordingId, error) => invoke("recording:stop", recordingId, error),
    onStopRequested: (listener) => {
      const handler = () => listener();
      ipcRenderer.on("recording:request-stop", handler);
      return () => ipcRenderer.removeListener("recording:request-stop", handler);
    },
  },
  processing: {
    retranscribe: (meetingId) => invoke("processing:retranscribe", meetingId),
    summarize: (meetingId) => invoke("processing:summarize", meetingId),
    progress: () => invoke("processing:progress"),
  },
  settings: {
    get: () => invoke("settings:get"),
    set: (patch) => invoke("settings:set", patch),
    models: () => invoke("settings:models"),
    locales: () => invoke("settings:locales"),
  },
  onChange: (listener) => {
    const handler = () => listener();
    ipcRenderer.on("changed", handler);
    return () => ipcRenderer.removeListener("changed", handler);
  },
};

contextBridge.exposeInMainWorld("dahlia", api);
