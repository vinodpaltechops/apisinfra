// Shows which pod answered at each hop. On a multi-replica deployment the
// instance names change as the Service load-balances, which makes the
// three-service topology visible instead of theoretical.
export default function ServiceChain({ meta, servedBy }) {
  const services = meta?.services ?? []

  return (
    <footer className="chain" aria-label="Service topology">
      <div className="chain-row">
        <span className="node node-static">
          <strong>frontend</strong>
          <em>nginx · static</em>
        </span>

        {services.map((service) => (
          <span key={service.name} className={`node node-${service.status === 'ok' ? 'up' : 'down'}`}>
            <strong>{service.name}</strong>
            <em title={service.instance}>
              v{service.version} · {service.instance}
            </em>
          </span>
        ))}

        {services.length === 0 && <span className="node node-down"><strong>backend</strong><em>unreachable</em></span>}
      </div>

      {servedBy && <p className="chain-note">Last catalog response assembled by <code>{servedBy}</code></p>}
      {meta?.cache && (
        <p className="chain-note">
          BFF cache: {meta.cache.entries} entries · {meta.cache.hits} hits · {meta.cache.misses} misses
        </p>
      )}
    </footer>
  )
}
