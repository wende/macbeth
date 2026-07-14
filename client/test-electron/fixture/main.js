// Minimal Electron main process for macbeth integration testing.
//
// Prints `FIXTURE_PID=<pid>` on stdout once the window is ready so the driver can
// connect by PID without depending on the app's localized name.
const { app, BrowserWindow } = require("electron");
const path = require("node:path");

app.setName("MacbethFixture");

function createWindow() {
  const win = new BrowserWindow({
    width: 600,
    height: 400,
    title: "MacbethFixture",
    webPreferences: { nodeIntegration: false, contextIsolation: true },
  });

  win.loadFile(path.join(__dirname, "index.html"));

  win.webContents.once("did-finish-load", () => {
    // eslint-disable-next-line no-console
    console.log(`FIXTURE_PID=${process.pid}`);
  });
}

app.whenReady().then(() => {
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  app.quit();
});
