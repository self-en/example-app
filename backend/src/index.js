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
      tags TEXT[] NOT NULL DEFAULT '{}',
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
  // Separate ALTER so branches with a table created before tags existed pick it up too.
  await pool.query(`ALTER TABLE todos ADD COLUMN IF NOT EXISTS tags TEXT[] NOT NULL DEFAULT '{}'`);
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
    const { rows } = tag
      ? await pool.query('SELECT * FROM todos WHERE $1 = ANY(tags) ORDER BY id', [tag])
      : await pool.query('SELECT * FROM todos ORDER BY id');
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
    const { rows } = await pool.query(
      'INSERT INTO todos (title, tags) VALUES ($1, $2) RETURNING *',
      [title, tags]
    );
    res.status(201).json(rows[0]);
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
