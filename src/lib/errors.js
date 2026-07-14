export class AppError extends Error {
  /**
   * @param {string} message
   * @param {{status?: number, code?: string, details?: unknown, cause?: unknown}} [options]
   */
  constructor(message, options = {}) {
    super(message, { cause: options.cause });
    this.name = "AppError";
    this.status = options.status ?? 500;
    this.code = options.code ?? "internal_error";
    this.details = options.details;
  }
}

/** @param {unknown} error */
export function asAppError(error) {
  if (error instanceof AppError) return error;
  const status = Number.isInteger(error?.status) ? error.status : 500;
  const message = error instanceof Error ? error.message : "Error inesperado";
  return new AppError(message, {
    status,
    code: status === 404 ? "not_found" : "internal_error",
    cause: error,
  });
}
