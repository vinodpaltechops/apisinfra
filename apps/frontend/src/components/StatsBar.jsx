// Everything here is computed by the BFF, not the browser — it is the clearest
// demonstration that the middle service does real work.
export default function StatsBar({ stats, cacheHit }) {
  const tiles = [
    { label: 'Matching items', value: stats.total_items },
    { label: 'On this page', value: stats.returned },
    { label: 'Average rating', value: stats.average_rating.toFixed(2) },
    { label: 'Reading time', value: `${stats.total_reading_minutes} min` },
  ]

  return (
    <section className="stats" aria-label="Catalog summary">
      {tiles.map((tile) => (
        <div className="stat" key={tile.label}>
          <span className="stat-value">{tile.value}</span>
          <span className="stat-label">{tile.label}</span>
        </div>
      ))}
      <div className={`stat stat-cache${cacheHit ? ' is-hit' : ''}`}>
        <span className="stat-value">{cacheHit ? 'HIT' : 'MISS'}</span>
        <span className="stat-label">BFF cache</span>
      </div>
    </section>
  )
}
