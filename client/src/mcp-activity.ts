export interface ActivityControl {
  begin(): Promise<string>;
  end(token: string): Promise<void>;
}

/**
 * Bracket a potentially computer-controlling MCP operation with a daemon glow
 * activity scope. Signaling is best-effort so an indicator failure can never
 * prevent the requested operation from running.
 */
export async function runWithActivity<T>(
  control: ActivityControl,
  operation: () => Promise<T>,
  onSignalError: (error: unknown) => void = () => {},
): Promise<T> {
  let token: string | undefined;
  try {
    token = await control.begin();
  } catch (error) {
    onSignalError(error);
  }

  try {
    return await operation();
  } finally {
    if (token) {
      try {
        await control.end(token);
      } catch (error) {
        onSignalError(error);
      }
    }
  }
}
