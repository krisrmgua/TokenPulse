import { contextBridge, ipcRenderer } from "electron";

function subscribe(channel: string, cb: () => void): () => void {
  const handler = () => cb();
  ipcRenderer.on(channel, handler);
  return () => ipcRenderer.removeListener(channel, handler);
}

contextBridge.exposeInMainWorld("tokenpulse", {
  getState: () => ipcRenderer.invoke("tp:getState"),
  refresh: () => ipcRenderer.invoke("tp:refresh"),
  setSource: (id: string, patch: unknown) => ipcRenderer.invoke("tp:setSource", id, patch),
  setPrefs: (patch: unknown) => ipcRenderer.invoke("tp:setPrefs", patch),
  resetPrefs: () => ipcRenderer.invoke("tp:resetPrefs"),
  saveOpenAIKey: (key: string) => ipcRenderer.invoke("tp:saveOpenAIKey", key),
  deleteOpenAIKey: () => ipcRenderer.invoke("tp:deleteOpenAIKey"),
  setOpenAIBalance: (usd: number | null) => ipcRenderer.invoke("tp:setOpenAIBalance", usd),
  openDataDir: () => ipcRenderer.invoke("tp:openDataDir"),
  openExternal: (url: string) => ipcRenderer.invoke("tp:openExternal", url),
  openNotificationSettings: () => ipcRenderer.invoke("tp:openNotificationSettings"),
  sendTestNotification: () => ipcRenderer.invoke("tp:sendTestNotification"),
  hide: () => ipcRenderer.invoke("tp:hide"),
  fitHeight: (height: number) => ipcRenderer.invoke("tp:fitHeight", height),
  quit: () => ipcRenderer.invoke("tp:quit"),
  onChanged: (cb: () => void) => subscribe("tp:changed", cb),
  onOpened: (cb: () => void) => subscribe("tp:opened", cb),
});
