const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('electronAPI', {
  showAlert: (options) => ipcRenderer.invoke('show-alert', options),
  showInputDialog: (options) => ipcRenderer.invoke('show-input-dialog', options)
})
