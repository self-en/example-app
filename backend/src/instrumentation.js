// Loaded via `node --import ./src/instrumentation.js` (see package.json's
// start script) so the SDK and its instrumentations are registered before
// express/pg are imported by index.js.
//
// Only started when OTEL_EXPORTER_OTLP_ENDPOINT is set: without a collector
// to send to, the OTLP exporters would otherwise retry against the default
// http://localhost:4318 and log connection-refused noise on every export
// interval, both in plain `docker run` local dev and in previews that don't
// wire up a collector.
if (process.env.OTEL_EXPORTER_OTLP_ENDPOINT) {
  const { diag, DiagConsoleLogger, DiagLogLevel } = await import(
    '@opentelemetry/api'
  );
  // Otherwise export failures (wrong endpoint, protocol mismatch, collector
  // down, ...) are swallowed silently by the SDK's internal no-op diag
  // logger - nothing would show up in `kubectl logs` to explain missing data.
  diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.ERROR);

  const { NodeSDK } = await import('@opentelemetry/sdk-node');
  const { getNodeAutoInstrumentations } = await import(
    '@opentelemetry/auto-instrumentations-node'
  );
  const { OTLPMetricExporter } = await import(
    '@opentelemetry/exporter-metrics-otlp-http'
  );
  const { OTLPLogExporter } = await import(
    '@opentelemetry/exporter-logs-otlp-http'
  );
  const { PeriodicExportingMetricReader } = await import(
    '@opentelemetry/sdk-metrics'
  );
  const { BatchLogRecordProcessor } = await import('@opentelemetry/sdk-logs');

  const sdk = new NodeSDK({
    serviceName: process.env.OTEL_SERVICE_NAME || 'example-app',
    metricReaders: [
      new PeriodicExportingMetricReader({ exporter: new OTLPMetricExporter() }),
    ],
    logRecordProcessors: [
      new BatchLogRecordProcessor({ exporter: new OTLPLogExporter() }),
    ],
    // Metrics and logs only - no traceExporter/spanProcessors, and an empty
    // array here (rather than omitting the option) stops NodeSDK from
    // falling back to OTEL_TRACES_EXPORTER's own default of otlp.
    spanProcessors: [],
    instrumentations: [
      getNodeAutoInstrumentations({
        // Noisy and not useful for this app - every static asset read
        // through express.static would otherwise generate a span/metric.
        '@opentelemetry/instrumentation-fs': { enabled: false },
      }),
    ],
  });

  sdk.start();

  for (const signal of ['SIGTERM', 'SIGINT']) {
    process.on(signal, () => {
      sdk.shutdown().finally(() => process.exit(0));
    });
  }
}
