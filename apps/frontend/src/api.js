// All calls are same-origin against /api/v1 — see vite.config.js for why.

const BASE = '/api/v1'

async function request(path, { signal } = {}) {
  const response = await fetch(`${BASE}${path}`, {
    signal,
    headers: { Accept: 'application/json' },
  })

  if (!response.ok) {
    // 503 is the BFF telling us content-api is down — worth saying plainly
    // rather than showing a generic failure.
    const detail =
      response.status === 503
        ? 'The content service is unavailable. The backend is up but cannot reach content-api.'
        : `Request failed with ${response.status}`
    throw new Error(detail)
  }

  return response.json()
}

export function fetchCatalog({ category, q, limit = 20, offset = 0 }, options) {
  const params = new URLSearchParams({ limit: String(limit), offset: String(offset) })
  if (category) params.set('category', category)
  if (q) params.set('q', q)

  return request(`/catalog?${params.toString()}`, options)
}

export function fetchMeta(options) {
  return request('/meta', options)
}
