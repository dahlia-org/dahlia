// The renderer gets exactly two operations; no Node, file system or arbitrary IPC is exposed.
import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("dahliaDesktop", {
  config: () => ipcRenderer.invoke("dahlia:config") as Promise<{ serverOrigin: string }>,
  signIn: (next: string) => ipcRenderer.invoke("dahlia:sign-in", next) as Promise<boolean>,
});
