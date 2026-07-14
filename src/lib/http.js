import { AppError } from "./errors.js";

const USER_AGENT = "RobloxSpriteForgeLocal/1.0";

/**
 * @param {string | URL} url
 * @param {RequestInit} [init]
 * @param {{timeoutMs?: number, service?: string, allowStatuses?: number[], retries?: number}} [options]
 */
export async function fetchJson(url, init = {}, options = {}) {
  const response = await fetchResponse(url, init, options);
  const text = await response.text();
  let body = null;
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = { raw: text.slice(0, 2_000) };
    }
  }
  if (!response.ok && !(options.allowStatuses ?? []).includes(response.status)) {
    throw upstreamHttpError(response.status, options.service, body);
  }
  return { body, status: response.status, headers: response.headers };
}

/**
 * @param {string | URL} url
 * @param {RequestInit} [init]
 * @param {{timeoutMs?: number, service?: string, maxBytes?: number, allowStatuses?: number[], retries?: number}} [options]
 */
export async function fetchBuffer(url, init = {}, options = {}) {
  const response = await fetchResponse(url, init, options);
  if (!response.ok && !(options.allowStatuses ?? []).includes(response.status)) {
    throw upstreamHttpError(response.status, options.service);
  }
  const maxBytes = options.maxBytes ?? 32 * 1024 * 1024;
  const declaredLength = Number(response.headers.get("content-length") ?? 0);
  if (declaredLength > maxBytes) {
    throw new AppError("La respuesta excede el tamaño permitido.", {
      status: 413,
      code: "upstream_response_too_large",
    });
  }
  const arrayBuffer = await response.arrayBuffer();
  if (arrayBuffer.byteLength > maxBytes) {
    throw new AppError("La respuesta excede el tamaño permitido.", {
      status: 413,
      code: "upstream_response_too_large",
    });
  }
  return {
    buffer: Buffer.from(arrayBuffer),
    status: response.status,
    contentType: response.headers.get("content-type") ?? "application/octet-stream",
  };
}

async function fetchResponse(url, init, options) {
  const retries = Math.max(0, Number(options.retries ?? 1));
  let lastError;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    const timeoutSignal = AbortSignal.timeout(options.timeoutMs ?? 20_000);
    const signal = init.signal ? AbortSignal.any([timeoutSignal, init.signal]) : timeoutSignal;
    try {
      const response = await fetch(url, {
        ...init,
        headers: { "user-agent": USER_AGENT, ...(init.headers ?? {}) },
        signal,
      });
      if ([429, 500, 502, 503, 504].includes(response.status) && attempt < retries) {
        lastError = upstreamHttpError(response.status, options.service);
        await response.arrayBuffer().catch(() => {});
      } else {
        return response;
      }
    } catch (error) {
      if (init.signal?.aborted) throw cancellationError(error);
      lastError = connectionError(error, options.service);
      if (attempt >= retries) throw lastError;
    }
    await sleep(350 * (attempt + 1), init.signal);
  }
  throw lastError ?? new AppError("No se pudo completar la solicitud externa.");
}

function upstreamHttpError(status, service = "El servicio externo", body) {
  return new AppError(`${service} respondió con HTTP ${status}.`, {
    status: status >= 500 || status === 429 ? 502 : status,
    code: "upstream_http_error",
    details: { upstreamStatus: status, ...(body !== undefined ? { body } : {}) },
  });
}

function connectionError(error, service = "el servicio externo") {
  const timedOut = error instanceof Error && ["AbortError", "TimeoutError"].includes(error.name);
  return new AppError(
    timedOut ? `${service} tardó demasiado.` : `No se pudo conectar con ${service}.`,
    {
      status: 502,
      code: timedOut ? "upstream_timeout" : "upstream_connection_error",
      cause: error,
    },
  );
}

function cancellationError(error) {
  return new AppError("Operación cancelada.", {
    status: 499,
    code: "operation_canceled",
    cause: error,
  });
}

export function sleep(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(cancellationError(signal.reason));
      return;
    }
    const onAbort = () => {
      clearTimeout(timer);
      reject(cancellationError(signal?.reason));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}
