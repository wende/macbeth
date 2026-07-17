const { app, BrowserWindow, ipcMain, dialog } = require('electron')
const path = require('path')

let mainWindow

app.setName('Macbeth Electron TestApp')

function createWindow () {
  mainWindow = new BrowserWindow({
    width: 640,
    height: 880,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  })

  mainWindow.loadFile('index.html')

  // Uncomment to open DevTools by default
  // mainWindow.webContents.openDevTools()
}

app.whenReady().then(() => {
  createWindow()

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') app.quit()
})

// Handle modal dialog requests from renderer
ipcMain.handle('show-alert', async (_event, { message, detail }) => {
  const result = await dialog.showMessageBox(mainWindow, {
    type: 'warning',
    buttons: ['OK', 'Cancel', 'Delete'],
    defaultId: 0,
    cancelId: 1,
    message: message || 'Confirm Action',
    detail: detail || 'Are you sure you want to proceed?'
  })
  return result.response
})

ipcMain.handle('show-input-dialog', async (_event, { title, label, value }) => {
  // Electron doesn't have a native input dialog, so we use a custom approach
  // For testing purposes, we'll show a message box with a prompt
  const { response } = await dialog.showMessageBox(mainWindow, {
    type: 'question',
    buttons: ['Submit', 'Cancel'],
    defaultId: 0,
    message: title || 'Enter value',
    detail: label || 'Type your input in the main window text field and click Submit'
  })
  return response === 0 ? 'user-input-value' : null
})
