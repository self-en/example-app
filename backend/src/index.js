import express from 'express';
import { Pool } from 'pg';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { logs, SeverityNumber } from '@opentelemetry/api-logs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const port = process.env.PORT || 3000;

// No-op unless instrumentation.js registered a LoggerProvider (i.e.
// OTEL_EXPORTER_OTLP_ENDPOINT is set), so this is safe to call unconditionally.
const otelLogger = logs.getLogger('example-app');

// JSON on stdout (so `kubectl logs`/Loki get a level and structured fields
// even though this app's OTLP logs currently 404 against Alloy - see
// self-en/infra's otelcol.receiver.otlp config, which only wires a metrics
// output) plus the OTel log record, for whenever that pipeline exists.
function log(severityText, message, attributes = {}) {
  const line = (severityText === 'ERROR' ? console.error : console.log).bind(console);
  line(JSON.stringify({ time: new Date().toISOString(), level: severityText.toLowerCase(), msg: message, ...attributes }));
  otelLogger.emit({
    severityNumber: SeverityNumber[severityText],
    severityText,
    body: message,
    attributes,
  });
}

function logError(message, err) {
  log('ERROR', message, err ? { error: { name: err.name, message: err.message, stack: err.stack } } : {});
}

function logRequest(req, res, durationMs) {
  log('INFO', `${req.method} ${req.originalUrl} ${res.statusCode}`, {
    http_request_method: req.method,
    url_path: req.originalUrl,
    http_response_status_code: res.statusCode,
    http_server_request_duration_ms: durationMs,
  });
}

// pg's Pool reads PGHOST/PGUSER/PGPASSWORD/PGDATABASE/PGPORT itself when no
// config is passed, so either DATABASE_URL or the CloudNativePG-style discrete
// env vars work without extra code here.
const pool = new Pool(
  process.env.DATABASE_URL ? { connectionString: process.env.DATABASE_URL } : {}
);

async function ensureSchema() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS todos (
      id SERIAL PRIMARY KEY,
      title TEXT NOT NULL,
      completed BOOLEAN NOT NULL DEFAULT false,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS tags (
      id SERIAL PRIMARY KEY,
      name TEXT NOT NULL UNIQUE
    )
  `);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS todo_tags (
      todo_id INTEGER NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
      tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
      PRIMARY KEY (todo_id, tag_id)
    )
  `);

  // Branches whose todos table predates this table split still carry the
  // old todos.tags TEXT[] column; migrate its data into tags/todo_tags once
  // and drop it. Already-migrated/new branches have no such column, so this
  // is a no-op for them.
  const { rows } = await pool.query(`
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'todos' AND column_name = 'tags'
  `);
  if (rows.length) {
    await pool.query(`
      INSERT INTO tags (name)
      SELECT DISTINCT unnest(tags) FROM todos
      ON CONFLICT (name) DO NOTHING
    `);
    await pool.query(`
      INSERT INTO todo_tags (todo_id, tag_id)
      SELECT todos.id, tags.id
      FROM todos, unnest(todos.tags) AS tag_name
      JOIN tags ON tags.name = tag_name
      ON CONFLICT DO NOTHING
    `);
    await pool.query('ALTER TABLE todos DROP COLUMN tags');
  }
}

function normalizeTags(input) {
  if (!Array.isArray(input)) return [];
  const tags = new Set();
  for (const raw of input) {
    if (typeof raw !== 'string') continue;
    const tag = raw.trim();
    if (tag) tags.add(tag);
  }
  return [...tags];
}

const app = express();
app.use(express.json());

app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  res.on('finish', () => {
    const durationMs = Number(process.hrtime.bigint() - start) / 1e6;
    logRequest(req, res, durationMs);
  });
  next();
});

app.use(express.static(path.join(__dirname, '../../frontend')));

app.get('/api/health', (_req, res) => res.json({ status: 'ok' }));

app.get('/api/todos', async (req, res, next) => {
  try {
    const tag = typeof req.query.tag === 'string' ? req.query.tag.trim() : '';
    const { rows } = await pool.query(
      `
      SELECT t.id, t.title, t.completed, t.created_at,
             COALESCE(array_agg(tg.name ORDER BY tg.name) FILTER (WHERE tg.name IS NOT NULL), '{}') AS tags
      FROM todos t
      LEFT JOIN todo_tags tt ON tt.todo_id = t.id
      LEFT JOIN tags tg ON tg.id = tt.tag_id
      WHERE $1 = '' OR t.id IN (
        SELECT todo_id FROM todo_tags
        JOIN tags ON tags.id = todo_tags.tag_id
        WHERE tags.name = $1
      )
      GROUP BY t.id
      ORDER BY t.id
      `,
      [tag]
    );
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

app.get('/api/tags', async (_req, res, next) => {
  try {
    const { rows } = await pool.query(`
      SELECT tg.name, COUNT(tt.todo_id)::int AS todo_count
      FROM tags tg
      LEFT JOIN todo_tags tt ON tt.tag_id = tg.id
      GROUP BY tg.name
      ORDER BY tg.name
    `);
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

app.post('/api/todos', async (req, res, next) => {
  try {
    const title = (req.body?.title || '').trim();
    if (!title) return res.status(400).json({ error: 'title is required' });
    const tags = normalizeTags(req.body?.tags);

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const { rows } = await client.query(
        'INSERT INTO todos (title) VALUES ($1) RETURNING *',
        [title]
      );
      const todo = rows[0];
      for (const tagName of tags) {
        const { rows: tagRows } = await client.query(
          'INSERT INTO tags (name) VALUES ($1) ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id',
          [tagName]
        );
        await client.query('INSERT INTO todo_tags (todo_id, tag_id) VALUES ($1, $2)', [todo.id, tagRows[0].id]);
      }
      await client.query('COMMIT');
      res.status(201).json({ ...todo, tags });
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  } catch (err) {
    next(err);
  }
});

app.patch('/api/todos/:id', async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      'UPDATE todos SET completed = $1 WHERE id = $2 RETURNING *',
      [Boolean(req.body?.completed), req.params.id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'not found' });
    res.json(rows[0]);
  } catch (err) {
    next(err);
  }
});

app.delete('/api/todos/:id', async (req, res, next) => {
  try {
    await pool.query('DELETE FROM todos WHERE id = $1', [req.params.id]);
    res.status(204).end();
  } catch (err) {
    next(err);
  }
});

app.use((err, _req, res, _next) => {
  logError('request failed', err);
  res.status(500).json({ error: 'internal error' });
});

ensureSchema()
  .then(() => app.listen(port, () => log('INFO', 'example-app listening', { port })))
  .catch((err) => {
    logError('failed to connect to postgres', err);
    process.exit(1);
  });
