/**
 * Converts ArkTS Error/BusinessError/unknown values into a useful diagnostic.
 * JSON.stringify(new Error()) is usually "{}", which hides the real failure.
 */
export function errorText(value: Object | Error | string | number | undefined | null): string {
  if (value === undefined) return 'unknown error'
  if (value === null) return 'null error'
  if (typeof value === 'string' || typeof value === 'number') return `${value}`
  const error = value as Error
  if (error.message && error.message.length > 0) {
    return error.name && error.name.length > 0 ? `${error.name}: ${error.message}` : error.message
  }
  try {
    const encoded = JSON.stringify(value)
    return encoded.length > 2 ? encoded : `${value}`
  } catch (_) {
    return `${value}`
  }
}
