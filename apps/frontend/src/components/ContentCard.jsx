const dateFormat = new Intl.DateTimeFormat('en-GB', {
  day: 'numeric',
  month: 'short',
  year: 'numeric',
})

export default function ContentCard({ item, onTag }) {
  return (
    <li className="card">
      <div className="card-head">
        <span className="chip chip-category">{item.category}</span>
        {item.is_new && <span className="chip chip-new">New</span>}
      </div>

      <h2 className="card-title">
        <a href={item.url} target="_blank" rel="noreferrer noopener">
          {item.title}
        </a>
      </h2>

      <p className="card-summary">{item.summary}</p>

      <ul className="tags">
        {item.tags.map((tag) => (
          <li key={tag}>
            <button type="button" className="tag" onClick={() => onTag(tag)}>
              #{tag}
            </button>
          </li>
        ))}
      </ul>

      <footer className="card-foot">
        <span className="author">{item.author}</span>
        <span className="dot" aria-hidden="true">·</span>
        <time dateTime={item.published_on}>
          {dateFormat.format(new Date(`${item.published_on}T00:00:00`))}
        </time>
        <span className="dot" aria-hidden="true">·</span>
        <span>{item.reading_time_label}</span>
        <span className="rating" title={`Rated ${item.rating} out of 5`}>
          ★ {item.rating.toFixed(1)}
        </span>
      </footer>
    </li>
  )
}
