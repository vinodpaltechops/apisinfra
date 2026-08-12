import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchCatalog, fetchMeta } from './api'
import ContentCard from './components/ContentCard'
import FilterBar from './components/FilterBar'
import ServiceChain from './components/ServiceChain'
import StatsBar from './components/StatsBar'

const PAGE_SIZE = 12

export default function App() {
  const [catalog, setCatalog] = useState(null)
  const [meta, setMeta] = useState(null)
  const [category, setCategory] = useState('')
  const [search, setSearch] = useState('')
  const [query, setQuery] = useState('')
  const [page, setPage] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  // Debounce typing so every keystroke does not hit the BFF.
  useEffect(() => {
    const timer = setTimeout(() => {
      setQuery(search.trim())
      setPage(0)
    }, 250)
    return () => clearTimeout(timer)
  }, [search])

  const load = useCallback((signal) => {
    setLoading(true)
    return fetchCatalog(
      { category, q: query, limit: PAGE_SIZE, offset: page * PAGE_SIZE },
      { signal },
    )
      .then((data) => {
        setCatalog(data)
        setError(null)
      })
      .catch((err) => {
        if (err.name !== 'AbortError') setError(err.message)
      })
      .finally(() => {
        if (!signal?.aborted) setLoading(false)
      })
  }, [category, query, page])

  useEffect(() => {
    const controller = new AbortController()
    load(controller.signal)
    return () => controller.abort()
  }, [load])

  useEffect(() => {
    const controller = new AbortController()
    fetchMeta({ signal: controller.signal })
      .then(setMeta)
      .catch(() => setMeta(null))
    return () => controller.abort()
  }, [])

  // Keep the previous list visible while a new one loads — avoids the layout
  // collapsing on every filter change.
  const previous = useRef(null)
  if (catalog) previous.current = catalog
  const shown = catalog ?? previous.current

  const total = shown?.stats?.total_items ?? 0
  const lastPage = Math.max(0, Math.ceil(total / PAGE_SIZE) - 1)

  return (
    <div className="app">
      <header className="masthead">
        <div className="masthead-title">
          <span className="logo" aria-hidden="true">◈</span>
          <div>
            <h1>Content Hub</h1>
            <p>Cloud platform engineering library, served by three microservices on private AKS.</p>
          </div>
        </div>
      </header>

      <main>
        <FilterBar
          search={search}
          onSearch={setSearch}
          category={category}
          categories={meta?.categories ?? []}
          onCategory={(next) => {
            setCategory(next)
            setPage(0)
          }}
        />

        {shown && <StatsBar stats={shown.stats} cacheHit={shown.cache_hit} />}

        {error && (
          <div className="notice notice-error" role="alert">
            <strong>Could not load the catalog.</strong>
            <span>{error}</span>
            <button type="button" onClick={() => load()}>Retry</button>
          </div>
        )}

        {!error && !shown && loading && <div className="notice">Loading catalog…</div>}

        {!error && shown && shown.items.length === 0 && (
          <div className="notice">
            No content matches {query ? <code>{query}</code> : 'this filter'}
            {category && <> in <code>{category}</code></>}.
          </div>
        )}

        {!error && shown && shown.items.length > 0 && (
          <ul className={`grid${loading ? ' grid-loading' : ''}`}>
            {shown.items.map((item) => (
              <ContentCard key={item.id} item={item} onTag={(tag) => setSearch(tag)} />
            ))}
          </ul>
        )}

        {!error && total > PAGE_SIZE && (
          <nav className="pager" aria-label="Pagination">
            <button type="button" disabled={page === 0} onClick={() => setPage((p) => p - 1)}>
              ← Previous
            </button>
            <span>Page {page + 1} of {lastPage + 1}</span>
            <button type="button" disabled={page >= lastPage} onClick={() => setPage((p) => p + 1)}>
              Next →
            </button>
          </nav>
        )}
      </main>

      <ServiceChain meta={meta} servedBy={shown?.served_by} />
    </div>
  )
}
