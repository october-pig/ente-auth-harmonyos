/**
 * Error conversion helpers (ArkTS limits what may be thrown).
 */
export function toError(e: Object | undefined): Error {
  if (e instanceof Error) {
    return e;
  }
  if (e === undefined || e === null) {
    return new Error('unknown error');
  }
  const s: string = String(e);
  return new Error(s);
}

export function messageOf(e: Object | undefined): string {
  return toError(e).message;
}