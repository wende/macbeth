import * as net from "node:net";

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

interface JsonRpcResponse {
  jsonrpc: string;
  id: number | string | null;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

export class JsonRpcError extends Error {
  code: number;
  data?: unknown;

  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.name = "JsonRpcError";
    this.code = code;
    this.data = data;
  }
}

export class JsonRpcClient {
  private socket: net.Socket | null = null;
  private pending = new Map<number, PendingRequest>();
  private nextId = 1;
  private buffer = "";
  private requestTimeout: number;

  constructor(options?: { timeout?: number }) {
    this.requestTimeout = options?.timeout ?? 60_000;
  }

  async connect(socketPath: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ path: socketPath }, () => {
        this.socket = socket;
        // Don't keep the process alive just because the socket is open.
        // The event loop stays alive while awaited promises are pending.
        socket.unref();
        resolve();
      });

      socket.on("error", (err) => {
        if (!this.socket) {
          reject(err);
        }
      });

      socket.on("data", (data) => {
        this.buffer += data.toString();
        this.processBuffer();
      });

      socket.on("close", () => {
        for (const [, pending] of this.pending) {
          clearTimeout(pending.timer);
          pending.reject(new Error("Connection closed"));
        }
        this.pending.clear();
        this.socket = null;
      });
    });
  }

  async call<T = unknown>(
    method: string,
    params?: Record<string, unknown>
  ): Promise<T> {
    if (!this.socket) {
      throw new Error("Not connected");
    }

    const id = this.nextId++;
    const request = {
      jsonrpc: "2.0",
      method,
      params: params ?? {},
      id,
    };

    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Request timeout: ${method} (${this.requestTimeout}ms)`));
      }, this.requestTimeout);

      this.pending.set(id, {
        resolve: resolve as (value: unknown) => void,
        reject,
        timer,
      });

      this.socket!.write(JSON.stringify(request) + "\n");
    });
  }

  close(): void {
    if (this.socket) {
      this.socket.destroy();
      this.socket = null;
    }
  }

  get connected(): boolean {
    return this.socket !== null && !this.socket.destroyed;
  }

  private processBuffer(): void {
    const lines = this.buffer.split("\n");
    this.buffer = lines.pop() ?? "";

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      try {
        const response: JsonRpcResponse = JSON.parse(trimmed);
        if (response.id == null) continue;

        const id =
          typeof response.id === "string"
            ? parseInt(response.id, 10)
            : response.id;
        const pending = this.pending.get(id);
        if (!pending) continue;

        clearTimeout(pending.timer);
        this.pending.delete(id);

        if (response.error) {
          pending.reject(
            new JsonRpcError(
              response.error.code,
              response.error.message,
              response.error.data
            )
          );
        } else {
          pending.resolve(response.result);
        }
      } catch {
        // Skip malformed lines
      }
    }
  }
}
