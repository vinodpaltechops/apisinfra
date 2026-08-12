export default function FilterBar({ search, onSearch, category, categories, onCategory }) {
  return (
    <section className="filters">
      <label className="search">
        <span className="visually-hidden">Search content</span>
        <svg viewBox="0 0 24 24" aria-hidden="true" className="search-icon">
          <circle cx="11" cy="11" r="7" fill="none" stroke="currentColor" strokeWidth="2" />
          <path d="M16.5 16.5 21 21" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
        </svg>
        <input
          type="search"
          value={search}
          placeholder="Search titles, authors, tags…"
          onChange={(event) => onSearch(event.target.value)}
        />
        {search && (
          <button type="button" className="clear" onClick={() => onSearch('')} aria-label="Clear search">
            ×
          </button>
        )}
      </label>

      <div className="categories" role="group" aria-label="Filter by category">
        <button
          type="button"
          className={`filter-chip${category === '' ? ' is-active' : ''}`}
          onClick={() => onCategory('')}
        >
          All
        </button>
        {categories.map((c) => (
          <button
            key={c.name}
            type="button"
            className={`filter-chip${category === c.name ? ' is-active' : ''}`}
            onClick={() => onCategory(category === c.name ? '' : c.name)}
          >
            {c.name}
            <span className="count">{c.item_count}</span>
          </button>
        ))}
      </div>
    </section>
  )
}
