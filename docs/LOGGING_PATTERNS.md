# Flui Logging Patterns - Supported Formats

This document describes all log formats that Vector can automatically parse and extract metadata from.

## Automatic Parsing Capabilities

Vector's Kubernetes log collector automatically detects and parses the following log formats:

### Priority 1: JSON Structured Logs (Recommended)

**Best practice**: All applications should emit logs in JSON format for optimal parsing and querying.

**Supported JSON field names** (case-insensitive, multiple variants supported):
- **Level**: `level`, `severity`, `lvl`
- **Message**: `message`, `msg`, `text`
- **Timestamp**: `timestamp`, `time`, `ts`, `@timestamp`
- **Trace ID**: `trace_id`, `traceId`
- **Span ID**: `span_id`, `spanId`
- **User ID**: `user_id`, `userId`
- **Request ID**: `request_id`, `requestId`
- **Error Type**: `error_type`, `exception`

**Example JSON log**:
```json
{
  "timestamp": "2026-02-23T05:50:32.047Z",
  "level": "error",
  "message": "Database connection failed",
  "service": "flui-api",
  "trace_id": "abc123def456",
  "user_id": "12345",
  "error_type": "DatabaseConnectionError"
}
```

**Extracted in Loki**:
- `level` = `error`
- `trace_id` = `abc123def456`
- `user_id` = `12345`
- Message = `Database connection failed`

---

### Priority 2: Text Patterns (Legacy/Fallback)

For applications that cannot be modified to use JSON, Vector supports these common text patterns:

#### Pattern 1: .NET/Serilog

```
[2026-02-23 05:50:32.047 ERR] User authentication failed
[2026-02-23 05:50:32.047 INF] Request processed successfully
[2026-02-23 05:50:32.047 WRN] High memory usage detected
```

**Level mappings**:
- `TRC` → `trace`
- `DBG` → `debug`
- `INF` → `info`
- `WRN` → `warn`
- `ERR` → `error`
- `FTL` → `fatal`

**Loki label**: `level="error"`

---

#### Pattern 2: Java/Logback

```
2026-02-23 05:50:32.047 ERROR [com.flui.api.UserService] - Connection timeout
2026-02-23 05:50:32.047 INFO [com.flui.api.Controller] - Request received
2026-02-23 05:50:32.047 WARN [com.flui.api.Database] - Slow query detected
```

**Supported levels**: `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL`

**Loki label**: `level="error"`

---

#### Pattern 3: Node.js/Winston (text mode)

```
error: User authentication failed
info: Server started on port 3000
warn: Deprecated API endpoint called
```

**Supported levels**: `trace`, `debug`, `info`, `warn`, `error`

**Loki label**: `level="error"`

---

#### Pattern 4: PHP/Laravel

```
[2026-02-23 05:50:32] production.ERROR: Database connection failed
[2026-02-23 05:50:32] production.INFO: User logged in
[2026-02-23 05:50:32] production.WARNING: Cache miss
```

**Supported levels**: `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL`, `ALERT`, `EMERGENCY`

**Loki label**: `level="error"` (normalized to lowercase)

---

#### Pattern 5: Docker/Go

```
time="2026-02-23T05:50:32Z" level=error msg="Connection failed"
time="2026-02-23T05:50:32Z" level=info msg="Service started"
time="2026-02-23T05:50:32Z" level=warn msg="Retrying request"
```

**Supported levels**: Any lowercase level keyword

**Loki label**: `level="error"`

---

#### Pattern 6: Generic (Fallback)

Vector will attempt to extract log levels from any of these patterns:

```
[ERROR] Something went wrong
ERROR: Connection timeout
2026-02-23 05:50:32 WARN Connection slow
INFO - Processing request
```

**Supported keywords**: `TRACE`, `DEBUG`, `INFO`, `WARN`, `WARNING`, `ERROR`, `FATAL`, `CRITICAL` (case-insensitive)

**Loki label**: `level="error"` (normalized to lowercase)

---

## Loki Labels Available for Querying

After parsing, the following labels are available in Loki:

### Common Labels (all logs)
- `cluster_id` - Cluster identifier
- `cluster_name` - Cluster name
- `server_id` - Server identifier
- `hostname` - Node hostname
- `service` - Service name
- `source_type` - Source type (e.g., `kubernetes`, `journald`)
- `level` - Log level (`trace`, `debug`, `info`, `warn`, `error`, `fatal`)

### Kubernetes-specific Labels
- `namespace` - Kubernetes namespace
- `pod` - Full pod name
- `app` - Application name (extracted from pod name)
- `container` - Container name
- `node` - Node hostname
- `stream` - Output stream (`stdout`, `stderr`)

### Optional Structured Labels (JSON logs only)
- `trace_id` - Distributed tracing ID
- `user_id` - User identifier
- `request_id` - Request identifier

---

## Example Loki Queries

```logql
# All errors from flui-api
{app="flui-api", level="error"}

# All logs from a specific user (requires JSON logging with user_id)
{app="flui-api", user_id="12345"}

# All warnings and errors from default namespace
{namespace="default", level=~"warn|error"}

# Trace a specific distributed transaction (requires JSON logging with trace_id)
{trace_id="abc123def456"}

# All stderr logs (errors typically go to stderr)
{stream="stderr"}

# Logs from specific pod
{pod="flui-api-846c4f5dcc-66fzc"}
```

---

## Recommendations by Language/Framework

### Node.js

**Recommended Library**: [Pino](https://github.com/pinojs/pino)

```javascript
const pino = require('pino');
const logger = pino({
  level: 'info',
  formatters: {
    level: (label) => ({ level: label })
  }
});

logger.info({ userId: 123, traceId: 'abc123' }, 'User logged in');
// Output: {"level":"info","time":1708664432047,"msg":"User logged in","userId":123,"traceId":"abc123"}
```

**Alternative**: Winston (configure JSON format)

---

#### NestJS

**NestJS v11+** (Native JSON Support - Recommended)

Starting from version 11, NestJS supports native JSON logging without additional dependencies:

```typescript
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, {
    logger: {
      logLevels: ['log', 'error', 'warn', 'debug', 'verbose'],
      json: true, // Enable JSON output
    },
  });
  await app.listen(3000);
}
bootstrap();
```

**Output example**:
```json
{
  "level": "info",
  "timestamp": "2026-02-23T05:50:32.047Z",
  "message": "User logged in",
  "context": "UserService",
  "userId": 123,
  "traceId": "abc123"
}
```

**NestJS Pre-v11** (Use Pino)

For versions before v11, use [nestjs-pino](https://github.com/iamolegga/nestjs-pino):

```bash
npm install nestjs-pino pino-http
```

```typescript
import { Module } from '@nestjs/common';
import { LoggerModule } from 'nestjs-pino';

@Module({
  imports: [
    LoggerModule.forRoot({
      pinoHttp: {
        level: process.env.NODE_ENV !== 'production' ? 'debug' : 'info',
        transport: process.env.NODE_ENV !== 'production'
          ? { target: 'pino-pretty' }
          : undefined,
        serializers: {
          req: (req) => ({
            method: req.method,
            url: req.url,
          }),
        },
      },
    }),
  ],
})
export class AppModule {}
```

**Usage in services**:
```typescript
import { Injectable, Logger } from '@nestjs/common';
import { PinoLogger } from 'nestjs-pino';

@Injectable()
export class UserService {
  constructor(private readonly logger: PinoLogger) {
    this.logger.setContext(UserService.name);
  }

  login(userId: number) {
    this.logger.info({ userId, traceId: 'abc123' }, 'User logged in');
  }
}
```

---

### .NET

**Recommended Library**: [Serilog](https://serilog.net/) with JSON formatter

```csharp
using Serilog;
using Serilog.Formatting.Json;

Log.Logger = new LoggerConfiguration()
    .WriteTo.Console(new JsonFormatter())
    .CreateLogger();

Log.Information("User {UserId} logged in", userId);
```

**Alternative**: Use text format (automatically parsed by Vector)

```csharp
Log.Logger = new LoggerConfiguration()
    .WriteTo.Console(outputTemplate: "[{Timestamp:yyyy-MM-dd HH:mm:ss.fff} {Level:u3}] {Message:lj}{NewLine}")
    .CreateLogger();
```

---

### Java

**Recommended Library**: Logback with [logstash-logback-encoder](https://github.com/logfellow/logstash-logback-encoder)

```xml
<appender name="STDOUT" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LogstashEncoder">
        <includeMdc>false</includeMdc>
    </encoder>
</appender>
```

**Alternative**: Standard Logback format (automatically parsed by Vector)

---

### PHP

**Recommended Library**: [Monolog](https://github.com/Seldaek/monolog) with JSON formatter

```php
use Monolog\Logger;
use Monolog\Handler\StreamHandler;
use Monolog\Formatter\JsonFormatter;

$logger = new Logger('flui-api');
$handler = new StreamHandler('php://stdout', Logger::INFO);
$handler->setFormatter(new JsonFormatter());
$logger->pushHandler($handler);

$logger->info('User logged in', ['userId' => 123]);
```

**Alternative**: Laravel's default format is automatically parsed by Vector

---

### Python

**Recommended Library**: [structlog](https://www.structlog.org/)

```python
import structlog

structlog.configure(
    processors=[
        structlog.processors.JSONRenderer()
    ]
)

logger = structlog.get_logger()
logger.info("user_logged_in", user_id=123, trace_id="abc123")
```

---

### Go

**Recommended Library**: [zap](https://github.com/uber-go/zap) or [zerolog](https://github.com/rs/zerolog)

```go
import "go.uber.org/zap"

logger, _ := zap.NewProduction()
defer logger.Sync()

logger.Info("User logged in",
    zap.Int("userId", 123),
    zap.String("traceId", "abc123"),
)
```

## Summary

**Best Practices:**
- Use JSON structured logging for all new applications
- Vector automatically parses common text patterns for legacy applications
- Leverage `level`, `trace_id`, `user_id` labels for powerful filtering capabilities
- Multi-language support: .NET, Java, Node.js, PHP, Python, Go

**Troubleshooting:**

For questions or issues with log parsing, check `/var/log/vector/vector.log` on the node.
